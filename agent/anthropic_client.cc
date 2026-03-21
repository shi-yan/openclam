#include "agent/anthropic_client.h"

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

// Parse SSE chunks; deliver complete "data: ..." lines to callback.
// A complete SSE message is terminated by a blank line ("\n\n").
class SSEParser {
 public:
  void feed(const char* data, size_t len,
            std::function<void(const std::string& event,
                               const std::string& payload)> on_event) {
    buf_.append(data, len);
    size_t pos;
    while ((pos = buf_.find("\n\n")) != std::string::npos) {
      std::string block = buf_.substr(0, pos);
      buf_.erase(0, pos + 2);

      std::string event_name;
      std::string event_data;
      std::istringstream iss(block);
      std::string line;
      while (std::getline(iss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.compare(0, 7, "event: ") == 0) event_name = line.substr(7);
        else if (line.compare(0, 6, "data: ") == 0) event_data = line.substr(6);
      }
      if (!event_data.empty() && event_data != "[DONE]")
        on_event(event_name, event_data);
    }
  }
 private:
  std::string buf_;
};

// Build the "messages" array in Anthropic format from internal Message list.
json build_messages(const std::vector<Message>& messages) {
  json arr = json::array();
  for (const auto& msg : messages) {
    json content = json::array();
    for (const auto& b : msg.content) {
      if (b.type == "text") {
        content.push_back({{"type","text"}, {"text", b.text}});
      } else if (b.type == "tool_use") {
        json inp = json::parse(b.input_json, nullptr, false);
        if (inp.is_discarded()) inp = json::object();
        content.push_back({{"type","tool_use"}, {"id",b.id},
                           {"name",b.name}, {"input", inp}});
      } else if (b.type == "tool_result") {
        // Content can be a string or an array
        json tool_content = json::array();
        tool_content.push_back({{"type","text"}, {"text", b.content_json}});
        json block = {{"type","tool_result"}, {"tool_use_id", b.id},
                      {"content", tool_content}};
        if (b.is_error) block["is_error"] = true;
        content.push_back(block);
      }
    }
    arr.push_back({{"role", msg.role}, {"content", content}});
  }
  return arr;
}

// Build the "tools" array in Anthropic format.
json build_tools(const std::vector<ToolDefinition>& tools) {
  json arr = json::array();
  for (const auto& t : tools) {
    json schema = json::parse(t.input_schema_json, nullptr, false);
    if (schema.is_discarded()) schema = {{"type","object"},{"properties",json::object()}};
    arr.push_back({{"name",t.name}, {"description",t.description},
                   {"input_schema", schema}});
  }
  return arr;
}

}  // namespace

// ---------------------------------------------------------------------------
// AnthropicClient
// ---------------------------------------------------------------------------

AnthropicClient::AnthropicClient(std::string model, std::string api_key,
                                 int max_tokens, int thinking_budget)
    : model_(std::move(model)),
      api_key_(std::move(api_key)),
      max_tokens_(max_tokens),
      thinking_budget_(thinking_budget) {}

LlmResponse AnthropicClient::complete(
    const std::string&                 system_prompt,
    const std::vector<Message>&        messages,
    const std::vector<ToolDefinition>& tools,
    std::function<void(StreamDelta)>   on_delta,
    std::atomic<bool>*                 cancel_flag) {

  // Build request body.
  json body = {
    {"model",      model_},
    {"max_tokens", max_tokens_},
    {"stream",     true},
    {"system",     system_prompt},
    {"messages",   build_messages(messages)},
  };
  if (!tools.empty())
    body["tools"] = build_tools(tools);
  if (thinking_budget_ > 0) {
    body["thinking"] = {{"type","enabled"}, {"budget_tokens", thinking_budget_}};
  }

  // State for streaming parse.
  LlmResponse response;
  // content_blocks[index] accumulates streaming content per block index.
  struct BlockAccum {
    std::string type;  // "text" | "tool_use" | "thinking"
    std::string text;
    std::string id, name, args;
  };
  std::unordered_map<int, BlockAccum> blocks;

  SSEParser parser;
  bool aborted = false;

  httplib::SSLClient cli("api.anthropic.com");
  cli.set_connection_timeout(30);
  cli.set_read_timeout(120);

  httplib::Headers headers = {
    {"x-api-key",          api_key_},
    {"anthropic-version",  "2023-06-01"},
    {"content-type",       "application/json"},
    {"accept",             "text/event-stream"},
  };

  httplib::Request req;
  req.method  = "POST";
  req.path    = "/v1/messages";
  req.headers = headers;
  req.body    = body.dump();
  req.set_header("content-type", "application/json");

  req.content_receiver =
      [&](const char* data, size_t len,
          uint64_t /*offset*/, uint64_t /*total*/) -> bool {
        if (cancel_flag && cancel_flag->load(std::memory_order_relaxed)) {
          aborted = true;
          return false;
        }
        parser.feed(data, len, [&](const std::string& /*evt*/,
                                    const std::string& payload) {
          auto j = json::parse(payload, nullptr, false);
          if (j.is_discarded()) return;

          std::string t = j.value("type", "");

          if (t == "content_block_start") {
            int idx = j.value("index", -1);
            if (idx < 0) return;
            auto& cb = j["content_block"];
            BlockAccum& blk = blocks[idx];
            blk.type = cb.value("type","");
            if (blk.type == "tool_use") {
              blk.id   = cb.value("id","");
              blk.name = cb.value("name","");
            }
          } else if (t == "content_block_delta") {
            int idx = j.value("index", -1);
            if (idx < 0) return;
            auto& delta = j["delta"];
            std::string dtype = delta.value("type","");
            BlockAccum& blk = blocks[idx];

            if (dtype == "text_delta") {
              std::string chunk = delta.value("text","");
              blk.text += chunk;
              StreamDelta d; d.text = chunk;
              on_delta(d);
            } else if (dtype == "thinking_delta") {
              std::string chunk = delta.value("thinking","");
              blk.text += chunk;
              StreamDelta d; d.text = chunk; d.is_thinking = true;
              on_delta(d);
            } else if (dtype == "input_json_delta") {
              std::string chunk = delta.value("partial_json","");
              blk.args += chunk;
              StreamDelta d;
              d.tool_call_id   = blk.id;
              d.tool_call_name = blk.name;
              d.tool_call_args_delta = chunk;
              on_delta(d);
            }
          } else if (t == "content_block_stop") {
            int idx = j.value("index", -1);
            if (idx < 0) return;
            auto it = blocks.find(idx);
            if (it == blocks.end()) return;
            BlockAccum& blk = it->second;
            if (blk.type == "text" || blk.type == "thinking") {
              response.text += blk.text;
            } else if (blk.type == "tool_use") {
              ToolCall tc;
              tc.id         = blk.id;
              tc.name       = blk.name;
              tc.input_json = blk.args;
              response.tool_calls.push_back(std::move(tc));
            }
          } else if (t == "message_delta") {
            std::string sr = j["delta"].value("stop_reason","");
            if (sr == "tool_use")    response.stop_reason = StopReason::ToolUse;
            else if (sr == "max_tokens") response.stop_reason = StopReason::MaxTokens;
            else                     response.stop_reason = StopReason::EndTurn;
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
    response.error = "Anthropic API error " + std::to_string(res->status) +
                     ": " + res->body;
    return response;
  }
  return response;
}
