#pragma once

#include <string>
#include "agent/llm_client.h"

// ---------------------------------------------------------------------------
// AnthropicClient
//
// Implements LlmClient for Anthropic's Messages API (claude-* models).
// Streaming via SSE (text/event-stream).
// Supports extended thinking via budget_tokens.
// ---------------------------------------------------------------------------
class AnthropicClient : public LlmClient {
 public:
  // api_key: Anthropic API key.
  // model: e.g. "claude-opus-4-6", "claude-sonnet-4-6".
  // max_tokens: maximum tokens to generate (default 8096).
  // thinking_budget: >0 enables extended thinking with this token budget.
  AnthropicClient(std::string model, std::string api_key,
                  int max_tokens = 8096, int thinking_budget = 0);

  LlmResponse complete(
      const std::string&                 system_prompt,
      const std::vector<Message>&        messages,
      const std::vector<ToolDefinition>& tools,
      std::function<void(StreamDelta)>   on_delta,
      std::atomic<bool>*                 cancel_flag) override;

 private:
  std::string model_;
  std::string api_key_;
  int         max_tokens_;
  int         thinking_budget_;
};
