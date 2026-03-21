#include "agent/gemini_client.h"

#define CPPHTTPLIB_OPENSSL_SUPPORT
#define CPPHTTPLIB_NO_EXCEPTIONS
#include "httplib.h"

#include <nlohmann/json.hpp>

#include <cstdio>
#include <sstream>
#include <string>

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

// Translate internal messages to Gemini "contents" array.
// Rules:
//   "user" with text       → role:"user", parts:[{text}]
//   "assistant" with text  → role:"model", parts:[{text}]
//   "assistant" with tool  → role:"model", parts:[{functionCall:{name,args}}]
//   "user" with tool_result→ role:"user",  parts:[{functionResponse:{name,response}}]
json build_contents(const std::vector<Message>& messages) {
  json arr = json::array();
  for (const auto& msg : messages) {
    bool all_tool_results = !msg.content.empty();
    for (const auto& b : msg.content)
      if (b.type != "tool_result") { all_tool_results = false; break; }

    if (all_tool_results) {
      // Tool results: role "user" with functionResponse parts
      json parts = json::array();
      for (const auto& b : msg.content) {
        json resp_val = json::parse(b.content_json, nullptr, false);
        if (resp_val.is_discarded()) resp_val = {{"result", b.content_json}};
        parts.push_back({{"functionResponse",
                          {{"name", b.id},    // b.id = tool_use_id; we need the tool name
                           {"response", resp_val}}}});
      }
      arr.push_back({{"role","user"}, {"parts", parts}});
      continue;
    }

    std::string role = (msg.role == "assistant") ? "model" : "user";
    json parts = json::array();
    for (const auto& b : msg.content) {
      if (b.type == "text" && !b.text.empty()) {
        parts.push_back({{"text", b.text}});
      } else if (b.type == "tool_use") {
        json args = json::parse(b.input_json, nullptr, false);
        if (args.is_discarded()) args = json::object();
        parts.push_back({{"functionCall", {{"name", b.name}, {"args", args}}}});
      }
    }
    if (!parts.empty())
      arr.push_back({{"role", role}, {"parts", parts}});
  }
  return arr;
}

// Translate tool definitions to Gemini functionDeclarations.
json build_tools(const std::vector<ToolDefinition>& tools) {
  json decls = json::array();
  for (const auto& t : tools) {
    json params = json::parse(t.input_schema_json, nullptr, false);
    if (params.is_discarded()) params = {{"type","object"},{"properties",json::object()}};
    decls.push_back({{"name", t.name},
                     {"description", t.description},
                     {"parameters", params}});
  }
  return json::array({{{"functionDeclarations", decls}}});
}

}  // namespace

// ---------------------------------------------------------------------------
// GeminiClient
// ---------------------------------------------------------------------------

GeminiClient::GeminiClient(std::string model, std::string api_key, int max_tokens)
    : model_(std::move(model)),
      api_key_(std::move(api_key)),
      max_tokens_(max_tokens) {}

LlmResponse GeminiClient::complete(
    const std::string&                 system_prompt,
    const std::vector<Message>&        messages,
    const std::vector<ToolDefinition>& tools,
    std::function<void(StreamDelta)>   on_delta,
    std::atomic<bool>*                 cancel_flag) {

  json body = {
    {"contents",          build_contents(messages)},
    {"generationConfig",  {{"maxOutputTokens", max_tokens_}}},
  };
  if (!system_prompt.empty())
    body["systemInstruction"] = {{"parts", {{{"text", system_prompt}}}}};
  if (!tools.empty()) {
    body["tools"] = build_tools(tools);
    // Force function calling mode so the model doesn't mix structured output
    body["toolConfig"] = {{"functionCallingConfig", {{"mode","AUTO"}}}};
  }

  LlmResponse response;
  SSEParser parser;
  bool aborted = false;

  httplib::SSLClient cli("generativelanguage.googleapis.com");
  cli.set_connection_timeout(30);
  cli.set_read_timeout(120);

  std::string path = "/v1beta/models/" + model_ +
                     ":streamGenerateContent?alt=sse&key=" + api_key_;

  httplib::Headers headers = {{"Content-Type", "application/json"}};

  httplib::Request req;
  req.method  = "POST";
  req.path    = path;
  req.headers = headers;
  req.body    = body.dump();
  req.set_header("content-type", "application/json");

  req.content_receiver =
      [&](const char* data, size_t len,
          uint64_t /*offset*/, uint64_t /*total*/) -> bool {
        if (cancel_flag && cancel_flag->load(std::memory_order_relaxed)) {
          aborted = true; return false;
        }
        parser.feed(data, len, [&](const std::string& /*event*/,
                                    const std::string& payload) {
          auto j = json::parse(payload, nullptr, false);
          if (j.is_discarded()) return;
          if (!j.contains("candidates") || j["candidates"].empty()) return;

          auto& cand = j["candidates"][0];
          if (!cand.contains("content")) return;
          auto& content = cand["content"];

          for (auto& part : content.value("parts", json::array())) {
            if (part.contains("text")) {
              std::string chunk = part["text"].get<std::string>();
              response.text += chunk;
              StreamDelta d; d.text = chunk;
              on_delta(d);
            } else if (part.contains("functionCall")) {
              auto& fc = part["functionCall"];
              ToolCall tc;
              tc.name       = fc.value("name","");
              tc.id         = tc.name + "_" + std::to_string(response.tool_calls.size());
              tc.input_json = fc.value("args", json::object()).dump();
              // Emit streaming delta for tool call
              StreamDelta d;
              d.tool_call_id   = tc.id;
              d.tool_call_name = tc.name;
              d.tool_call_args_delta = tc.input_json;
              on_delta(d);
              response.tool_calls.push_back(std::move(tc));
            }
          }

          std::string finish = cand.value("finishReason","");
          if (!finish.empty() && finish != "FINISH_REASON_UNSPECIFIED") {
            response.stop_reason = response.tool_calls.empty()
                                   ? StopReason::EndTurn
                                   : StopReason::ToolUse;
            if (finish == "MAX_TOKENS") response.stop_reason = StopReason::MaxTokens;
          }
        });
        return true;
      };

  auto res = cli.send(req);

  if (aborted) {
    response.stop_reason = StopReason::Error; response.error = "cancelled";
    return response;
  }
  if (!res) {
    response.stop_reason = StopReason::Error;
    response.error = "HTTP error: " + httplib::to_string(res.error());
    return response;
  }
  if (res->status != 200) {
    response.stop_reason = StopReason::Error;
    response.error = "Gemini API error " + std::to_string(res->status) +
                     ": " + res->body;
    return response;
  }
  // If no finish reason was received, infer from tool calls
  if (response.stop_reason == StopReason::EndTurn && !response.tool_calls.empty())
    response.stop_reason = StopReason::ToolUse;
  return response;
}
