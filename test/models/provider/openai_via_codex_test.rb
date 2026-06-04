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

  test "budget readers default to Codex model limits" do
    with_env_overrides(
      "LLM_CONTEXT_WINDOW" => nil,
      "LLM_MAX_RESPONSE_TOKENS" => nil,
      "LLM_SYSTEM_PROMPT_RESERVE" => nil
    ) do
      Setting.stubs(:llm_context_window).returns(nil)
      Setting.stubs(:llm_max_response_tokens).returns(nil)

      provider = Provider::OpenaiViaCodex.new(client: stub, model: "openai-codex/gpt-5.4")

      assert_equal 1_050_000, provider.context_window
      assert_equal 128_000, provider.max_response_tokens
      assert_equal 256, provider.system_prompt_reserve
      assert_equal 1_050_000 - 128_000 - 256, provider.max_input_tokens
    end
  end

  test "budget readers use configured Codex model family limits" do
    with_env_overrides(
      "LLM_CONTEXT_WINDOW" => nil,
      "LLM_MAX_RESPONSE_TOKENS" => nil
    ) do
      Setting.stubs(:llm_context_window).returns(nil)
      Setting.stubs(:llm_max_response_tokens).returns(nil)

      provider = Provider::OpenaiViaCodex.new(client: stub, model: "openai-codex/gpt-5.4-mini")

      assert_equal 400_000, provider.context_window
      assert_equal 128_000, provider.max_response_tokens
    end
  end

  test "budget readers respect explicit env overrides" do
    with_env_overrides(
      "LLM_CONTEXT_WINDOW" => "8192",
      "LLM_MAX_RESPONSE_TOKENS" => "1024"
    ) do
      Setting.stubs(:llm_context_window).returns(nil)
      Setting.stubs(:llm_max_response_tokens).returns(nil)

      provider = Provider::OpenaiViaCodex.new(client: stub, model: "openai-codex/gpt-5.4")

      assert_equal 8192, provider.context_window
      assert_equal 1024, provider.max_response_tokens
      assert_equal 8192 - 1024 - 256, provider.max_input_tokens
    end
  end

  test "chat uses explicit message history instead of previous response id" do
    client = mock
    client.expects(:chat).with do |parameters:|
      parameters[:messages] == [
        { role: "user", content: "first" },
        { role: "assistant", content: "second" }
      ] && parameters.key?(:previous_response_id) == false
    end.returns({
      "id" => "resp_1",
      "model" => "gpt-5.4",
      "choices" => [ { "message" => { "role" => "assistant", "content" => "third" } } ],
      "usage" => { "input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2 }
    })

    provider = Provider::OpenaiViaCodex.new(client: client)

    response = provider.chat_response(
      "ignored when history exists",
      model: "openai-codex/gpt-5.4",
      messages: [
        { role: "user", content: "first" },
        { role: "assistant", content: "second" }
      ],
      previous_response_id: "resp_previous"
    )

    assert response.success?
    assert_equal "third", response.data.messages.first.output_text
  end
end
