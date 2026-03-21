#pragma once

#include <string>
#include "agent/llm_client.h"

// ---------------------------------------------------------------------------
// OpenAiClient
//
// Implements LlmClient for OpenAI's Responses API (/v1/responses).
// This is the newer stateful API, NOT the classic chat completions endpoint.
//
// Supported models: gpt-4o, gpt-4o-mini, o1, o3, o4-mini, etc.
// ---------------------------------------------------------------------------
class OpenAiClient : public LlmClient {
 public:
  OpenAiClient(std::string model, std::string api_key, int max_tokens = 4096);

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
};
