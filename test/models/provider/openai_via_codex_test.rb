require "test_helper"

class Provider::OpenaiViaCodexTest < ActiveSupport::TestCase
  test "defaults to codex-prefixed model" do
    provider = Provider::OpenaiViaCodex.new(client: stub)

    assert provider.supports_model?("openai-codex/gpt-5.4")
    assert_not provider.supports_model?("gpt-5.4")
    assert_equal "OpenAI via Codex", provider.provider_name
    assert_equal "openai-codex/gpt-5.4", Provider::OpenaiViaCodex.effective_model
  end

  test "usage provider is inferred as openai_codex without cost estimate" do
    assert_equal "openai_codex", LlmUsage.infer_provider("openai-codex/gpt-5.4")
    assert_nil LlmUsage.calculate_cost(model: "openai-codex/gpt-5.4", prompt_tokens: 10, completion_tokens: 10)
  end
end
