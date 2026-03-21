#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Common types shared by all LLM provider clients.
//
// The internal message format mirrors Claude's native format (richest subset).
// OpenAiClient and GeminiClient translate to/from their own wire formats.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Content blocks — one element within a Message::content array.
// ---------------------------------------------------------------------------
struct ContentBlock {
  std::string type;         // "text" | "tool_use" | "tool_result"

  // type == "text"
  std::string text;

  // type == "tool_use"  (assistant → request a tool call)
  std::string id;           // tool call ID; also used as matching ID for tool_result
  std::string name;         // tool name
  std::string input_json;   // JSON string of tool arguments

  // type == "tool_result"  (user → supply the tool call's result)
  // id   = tool_use_id this result corresponds to
  std::string content_json; // JSON string of the result payload
  bool        is_error = false;

  // Factories
  static ContentBlock text_block(std::string t) {
    ContentBlock b; b.type = "text"; b.text = std::move(t); return b;
  }
  static ContentBlock tool_use(std::string id_, std::string name_, std::string input) {
    ContentBlock b;
    b.type = "tool_use"; b.id = std::move(id_);
    b.name = std::move(name_); b.input_json = std::move(input);
    return b;
  }
  static ContentBlock tool_result(std::string tool_use_id, std::string content,
                                   bool error = false) {
    ContentBlock b;
    b.type = "tool_result"; b.id = std::move(tool_use_id);
    b.content_json = std::move(content); b.is_error = error;
    return b;
  }
};

// ---------------------------------------------------------------------------
// Message — one turn in the conversation.
// ---------------------------------------------------------------------------
struct Message {
  std::string               role;    // "user" | "assistant"
  std::vector<ContentBlock> content;

  static Message user(std::string text) {
    Message m; m.role = "user";
    m.content.push_back(ContentBlock::text_block(std::move(text)));
    return m;
  }
  static Message assistant(std::string text) {
    Message m; m.role = "assistant";
    m.content.push_back(ContentBlock::text_block(std::move(text)));
    return m;
  }
};

// ---------------------------------------------------------------------------
// ToolDefinition — describes one tool to the LLM.
// ---------------------------------------------------------------------------
struct ToolDefinition {
  std::string name;
  std::string description;
  std::string input_schema_json;  // JSON Schema object as a string
};

// ---------------------------------------------------------------------------
// StreamDelta — one chunk delivered to the on_delta callback during streaming.
// ---------------------------------------------------------------------------
struct StreamDelta {
  std::string text;               // text or thinking delta (may be empty)
  bool        is_thinking = false;// true for extended thinking content

  // Tool call streaming (partial args):
  std::string tool_call_id;
  std::string tool_call_name;
  std::string tool_call_args_delta;
};

// ---------------------------------------------------------------------------
// LlmResponse — returned when the stream ends.
// ---------------------------------------------------------------------------
enum class StopReason { EndTurn, ToolUse, MaxTokens, Error };

struct ToolCall {
  std::string id;
  std::string name;
  std::string input_json;  // complete JSON args string
};

struct LlmResponse {
  StopReason           stop_reason = StopReason::EndTurn;
  std::string          text;        // accumulated full text (empty on ToolUse)
  std::vector<ToolCall> tool_calls; // populated when stop_reason == ToolUse
  std::string          error;       // set when stop_reason == Error
};

// ---------------------------------------------------------------------------
// LlmClient — abstract interface.
//
// complete() is a blocking call that streams to on_delta and returns the full
// response when the stream ends.  It is called from the session worker thread.
// cancel_flag is polled between SSE events; set it to abort mid-stream.
// ---------------------------------------------------------------------------
class LlmClient {
 public:
  virtual ~LlmClient() = default;

  virtual LlmResponse complete(
      const std::string&                 system_prompt,
      const std::vector<Message>&        messages,
      const std::vector<ToolDefinition>& tools,
      std::function<void(StreamDelta)>   on_delta,
      std::atomic<bool>*                 cancel_flag = nullptr) = 0;
};

// Factory — selects implementation based on model name prefix:
//   "claude-*"   → AnthropicClient
//   "gpt-*|o*"   → OpenAiClient  (Responses API)
//   "gemini-*"   → GeminiClient
std::unique_ptr<LlmClient> make_llm_client(const std::string& model,
                                            const std::string& api_key);
