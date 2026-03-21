#include "agent/llm_client.h"

#include "agent/anthropic_client.h"
#include "agent/openai_client.h"
#include "agent/gemini_client.h"

std::unique_ptr<LlmClient> make_llm_client(const std::string& model,
                                            const std::string& api_key) {
  // Prefix-based dispatch
  if (model.compare(0, 7, "claude-") == 0)
    return std::make_unique<AnthropicClient>(model, api_key);

  if (model.compare(0, 7, "gemini-") == 0)
    return std::make_unique<GeminiClient>(model, api_key);

  // OpenAI: gpt-*, o1, o3, o4-mini, etc.
  return std::make_unique<OpenAiClient>(model, api_key);
}
