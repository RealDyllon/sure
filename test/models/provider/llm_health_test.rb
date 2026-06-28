require "test_helper"

# Provider health visibility + error sanitization coverage for OpenSpec
# `ai-provider-reliability`.
class Provider::LlmHealthTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "reports available provider, effective model, and budget sources when OpenAI is configured" do
    with_env_overrides(
      "OPENAI_ACCESS_TOKEN" => "sk-test-abc12345",
      "LLM_PROVIDER" => nil,
      "OPENAI_MODEL" => nil,
      "LLM_CONTEXT_WINDOW" => nil,
      "LLM_MAX_RESPONSE_TOKENS" => nil,
      "LLM_MAX_ITEMS_PER_CALL" => nil
    ) do
      Setting.stubs(:effective_llm_provider).returns("openai")
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:openai_model).returns(nil)
      Setting.stubs(:llm_context_window).returns(nil)
      Setting.stubs(:llm_max_response_tokens).returns(nil)
      Setting.stubs(:llm_max_items_per_call).returns(nil)

      health = Provider::LlmHealth.for_family(@family)

      assert health.available?
      assert_equal :openai, health.provider_key
      assert health.effective_model.present?
      assert_equal :provider_default, health.context_window.source
      assert health.context_window.value.to_i.positive?
    end
  end

  test "reports unavailable state when no provider can be constructed" do
    with_env_overrides(
      "OPENAI_ACCESS_TOKEN" => nil,
      "LLM_PROVIDER" => nil,
      "OPENAI_MODEL" => nil
    ) do
      Setting.stubs(:effective_llm_provider).returns("openai")
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:openai_model).returns(nil)
      Setting.stubs(:llm_provider).returns("openai")

      health = Provider::LlmHealth.for_family(@family)

      assert_not health.available?
      assert_not health.auth_configured?
      assert_equal :auth_config_missing, health.unavailable_reason
    end
  end

  test "marks environment-backed budgets as :env source" do
    with_env_overrides(
      "OPENAI_ACCESS_TOKEN" => "sk-test-abc12345",
      "LLM_PROVIDER" => nil,
      "OPENAI_MODEL" => nil,
      "LLM_CONTEXT_WINDOW" => "8192",
      "LLM_MAX_RESPONSE_TOKENS" => "1024",
      "LLM_MAX_ITEMS_PER_CALL" => "10"
    ) do
      Setting.stubs(:effective_llm_provider).returns("openai")
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:openai_model).returns(nil)
      Setting.stubs(:llm_context_window).returns(nil)
      Setting.stubs(:llm_max_response_tokens).returns(nil)
      Setting.stubs(:llm_max_items_per_call).returns(nil)

      health = Provider::LlmHealth.for_family(@family)

      assert health.available?
      assert_equal 8192, health.context_window.value
      assert_equal :env, health.context_window.source
      assert_equal :env, health.max_response_tokens.source
      assert_equal :env, health.max_items_per_call.source
    end
  end

  test "last error sanitizes API keys, tokens, and stack traces" do
    chat = chats(:one)
    chat.add_error(StandardError.new("OpenAI API error 401: invalid api key sk-leaked-AbCdEf123456 token=secretpassword123 from /Users/dyllon/app/models/foo.rb:42:in `bar'"))

    health = Provider::LlmHealth.for_family(@family)
    last_error = health.last_error(chat)

    assert last_error.present?
    assert last_error.message.present?
    technical = last_error.technical_message
    refute_match(/sk-leaked/, technical)
    refute_match(/secretpassword123/, technical)
    refute_match(%r{/Users/dyllon/app}, technical)
    refute_match(/in `bar'/, technical)
    # Keeps useful HTTP status context.
    assert_match(/401/, technical)
  end

  test "last error omits oversized provider payloads" do
    chat = chats(:one)
    huge = "OpenAI API error 429: " + ("x" * 5_000)
    chat.add_error(StandardError.new(huge))

    health = Provider::LlmHealth.for_family(@family)
    last_error = health.last_error(chat)

    assert last_error.present?
    assert_operator last_error.technical_message.length, :<=, 1_100
  end

  test "last error returns nil when chat has no error" do
    chat = chats(:one)
    chat.update!(error: nil)

    health = Provider::LlmHealth.for_family(@family)

    assert_nil health.last_error(chat)
  end
end