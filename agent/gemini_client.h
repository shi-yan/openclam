#pragma once

#include <string>
#include "agent/llm_client.h"

// ---------------------------------------------------------------------------
// GeminiClient
//
// Implements LlmClient for Google's Gemini API (streamGenerateContent).
// Uses SSE streaming (alt=sse query param).
//
// Supported models: gemini-2.0-flash, gemini-2.5-pro, etc.
//
// Notes:
//  - Tool results are sent as "user" role with functionResponse parts (Gemini quirk).
//  - Tool-calling mode is always used; structured output is not combined with tools.
//  - The API key is passed as a query parameter.
// ---------------------------------------------------------------------------
class GeminiClient : public LlmClient {
 public:
  GeminiClient(std::string model, std::string api_key, int max_tokens = 8096);

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
