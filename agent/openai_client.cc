#include "agent/openai_client.h"

#define CPPHTTPLIB_OPENSSL_SUPPORT
#define CPPHTTPLIB_NO_EXCEPTIONS
#include "httplib.h"

#include <nlohmann/json.hpp>

#include <cstdio>
#include <sstream>
#include <string>
#include <unordered_map>

using json = nlohmann::json;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

namespace {

class SSEParser {
 public:
  void feed(const char* data, size_t len,
            std::function<void(const std::string&, const std::string&)> cb) {
    buf_.append(data, len);
    size_t pos;
    while ((pos = buf_.find("\n\n")) != std::string::npos) {
      std::string block = buf_.substr(0, pos);
      buf_.erase(0, pos + 2);
      std::string ev, dat;
      std::istringstream iss(block);
      std::string line;
      while (std::getline(iss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.compare(0, 7, "event: ") == 0) ev  = line.substr(7);
        else if (line.compare(0, 6, "data: ") == 0) dat = line.substr(6);
      }
      if (!dat.empty() && dat != "[DONE]") cb(ev, dat);
    }
  }
 private:
  std::string buf_;
};

// Translate internal messages to OpenAI Responses API input array.
//
// Internal format (Claude-style):
//   user message      → {"role":"user","content":"text"}
//   assistant message → {"role":"assistant","content":"text"}
//                       + {"type":"function_call","call_id":...} per tool_use
//   user w/ tool res  → {"type":"function_call_output","call_id":...} per tool_result
json build_input(const std::vector<Message>& messages) {
  json input = json::array();

  for (const auto& msg : messages) {
    // Detect if this is a tool-result-only user message
    bool all_tool_results = !msg.content.empty();
    for (const auto& b : msg.content) {
      if (b.type != "tool_result") { all_tool_results = false; break; }
    }

    if (all_tool_results) {
      for (const auto& b : msg.content) {
        input.push_back({{"type",    "function_call_output"},
                         {"call_id", b.id},
                         {"output",  b.content_json}});
      }
      continue;
    }

    if (msg.role == "assistant") {
      // Text portion first (if any)
      std::string text;
      for (const auto& b : msg.content)
        if (b.type == "text") text += b.text;
      if (!text.empty())
        input.push_back({{"role","assistant"}, {"content", text}});

      // Then function_call items
      for (const auto& b : msg.content) {
        if (b.type == "tool_use") {
          input.push_back({{"type",      "function_call"},
                           {"call_id",   b.id},
                           {"name",      b.name},
                           {"arguments", b.input_json}});
        }
      }
      continue;
    }

    // Regular user message
    std::string text;
    for (const auto& b : msg.content)
      if (b.type == "text") text += b.text;
    if (!text.empty())
      input.push_back({{"role","user"}, {"content", text}});
  }
  return input;
}

// Translate tool definitions to OpenAI Responses API format.
json build_tools(const std::vector<ToolDefinition>& tools) {
  json arr = json::array();
  for (const auto& t : tools) {
    json params = json::parse(t.input_schema_json, nullptr, false);
    if (params.is_discarded()) params = {{"type","object"},{"properties",json::object()}};
    arr.push_back({{"type","function"},
                   {"name", t.name},
                   {"description", t.description},
                   {"parameters", params}});
  }
  return arr;
}

}  // namespace

// ---------------------------------------------------------------------------
// OpenAiClient
// ---------------------------------------------------------------------------

OpenAiClient::OpenAiClient(std::string model, std::string api_key,
                           int max_tokens)
    : model_(std::move(model)),
      api_key_(std::move(api_key)),
      max_tokens_(max_tokens) {}

LlmResponse OpenAiClient::complete(
    const std::string&                 system_prompt,
    const std::vector<Message>&        messages,
    const std::vector<ToolDefinition>& tools,
    std::function<void(StreamDelta)>   on_delta,
    std::atomic<bool>*                 cancel_flag) {

  json body = {
    {"model",        model_},
    {"stream",       true},
    {"max_output_tokens", max_tokens_},
  };
  if (!system_prompt.empty()) body["instructions"] = system_prompt;
  body["input"] = build_input(messages);
  if (!tools.empty()) body["tools"] = build_tools(tools);

  // Per-call state
  LlmResponse response;
  // Accumulate function_call arguments per call_id
  struct FnAcc { std::string name; std::string args; };
  std::unordered_map<std::string, FnAcc> fn_calls;  // call_id → accumulated
  SSEParser parser;
  bool aborted = false;

  httplib::SSLClient cli("api.openai.com");
  cli.set_connection_timeout(30);
  cli.set_read_timeout(120);

  httplib::Headers headers = {
    {"Authorization", "Bearer " + api_key_},
    {"Content-Type",  "application/json"},
  };

  httplib::Request req;
  req.method  = "POST";
  req.path    = "/v1/responses";
  req.headers = headers;
  req.body    = body.dump();
  req.set_header("content-type", "application/json");

  req.content_receiver =
      [&](const char* data, size_t len,
          uint64_t /*offset*/, uint64_t /*total*/) -> bool {
        if (cancel_flag && cancel_flag->load(std::memory_order_relaxed)) {
          aborted = true; return false;
        }
        parser.feed(data, len, [&](const std::string& event,
                                    const std::string& payload) {
          auto j = json::parse(payload, nullptr, false);
          if (j.is_discarded()) return;

          // response.output_item.added — new output item starts
          if (event == "response.output_item.added") {
            auto& item = j["item"];
            if (item.value("type","") == "function_call") {
              std::string cid = item.value("call_id","");
              fn_calls[cid].name = item.value("name","");
            }
          }
          // response.content_part.delta — text streaming
          else if (event == "response.content_part.delta") {
            auto& delta = j["delta"];
            if (delta.value("type","") == "output_text_delta") {
              std::string chunk = delta.value("text","");
              response.text += chunk;
              StreamDelta d; d.text = chunk;
              on_delta(d);
            }
          }
          // response.function_call_arguments.delta — tool args streaming
          else if (event == "response.function_call_arguments.delta") {
            std::string cid   = j.value("call_id","");
            std::string chunk = j.value("delta","");
            fn_calls[cid].args += chunk;
            StreamDelta d;
            d.tool_call_id         = cid;
            d.tool_call_name       = fn_calls[cid].name;
            d.tool_call_args_delta = chunk;
            on_delta(d);
          }
          // response.completed — finalize
          else if (event == "response.completed") {
            // Collect completed function calls
            for (auto& [cid, fn] : fn_calls) {
              ToolCall tc;
              tc.id         = cid;
              tc.name       = fn.name;
              tc.input_json = fn.args;
              response.tool_calls.push_back(std::move(tc));
            }
            response.stop_reason = response.tool_calls.empty()
                                   ? StopReason::EndTurn
                                   : StopReason::ToolUse;
          }
        });
        return true;
      };

  auto res = cli.send(req);

  if (aborted) {
    response.stop_reason = StopReason::Error;
    response.error = "cancelled";
    return response;
  }
  if (!res) {
    response.stop_reason = StopReason::Error;
    response.error = "HTTP error: " + httplib::to_string(res.error());
    return response;
  }
  if (res->status != 200) {
    response.stop_reason = StopReason::Error;
    response.error = "OpenAI API error " + std::to_string(res->status) +
                     ": " + res->body;
    return response;
  }
  return response;
}
