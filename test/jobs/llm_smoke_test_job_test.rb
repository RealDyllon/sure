# frozen_string_literal: true

require "test_helper"

# Worker-runtime AI smoke test coverage for OpenSpec `ai-provider-reliability`.
class LlmSmokeTestJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    Provider::LlmSmokeTest.clear(@family)
  end

  test "records a sanitized provider-unavailable failure when no provider can be constructed" do
    with_env_overrides(
      "OPENAI_ACCESS_TOKEN" => nil,
      "LLM_PROVIDER" => nil,
      "OPENAI_MODEL" => nil
    ) do
      Setting.stubs(:effective_llm_provider).returns("openai")
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:openai_model).returns(nil)
      Setting.stubs(:llm_provider).returns("openai")

      perform_enqueued_jobs { LlmSmokeTestJob.perform_later(@family.id) }

      result = Provider::LlmSmokeTest.current(@family)
      puts "DEBUG status=#{result.status.inspect} error=#{result.error.inspect}"
      assert result.failed?
      assert_match(/Provider unavailable/i, result.error)
      assert_no_match(/sk-/, result.error.to_s)
    end
  end

  test "records success when the worker provider call succeeds" do
    with_env_overrides(
      "OPENAI_ACCESS_TOKEN" => "sk-test-abc12345",
      "LLM_PROVIDER" => nil,
      "OPENAI_MODEL" => nil
    ) do
      Setting.stubs(:effective_llm_provider).returns("openai")
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:openai_model).returns(nil)

      fake_provider = stub
      fake_provider.stubs(:provider_name).returns("OpenAI")
      success = stub
      success.stubs(:success?).returns(true)
      fake_provider.expects(:chat_response).returns(success)

      Provider::LlmHealth.stubs(:for_family).with do |fam|
        fam.id == @family.id
      end.returns(stub(
        available?: true,
        provider_key: :openai,
        provider: fake_provider,
        effective_model: "gpt-4.1",
        context_window: stub(value: 8192, source: :env),
        max_response_tokens: stub(value: 1024, source: :env),
        max_items_per_call: stub(value: 10, source: :env)
      ))

      perform_enqueued_jobs { LlmSmokeTestJob.perform_later(@family.id) }

      result = Provider::LlmSmokeTest.current(@family)
      assert result.succeeded?
      assert_equal "gpt-4.1", result.model
      assert_equal 8192, result.context_window
      assert result.finished_at.present?
    end
  end

  test "records a sanitized failure when the provider raises" do
    fake_provider = stub
    fake_provider.expects(:chat_response).raises(StandardError.new("OpenAI API error 401: invalid api key sk-leaked-AbCdEf123456"))

    Provider::LlmHealth.stubs(:for_family).with do |fam|
      fam.id == @family.id
    end.returns(stub(
      available?: true,
      provider_key: :openai,
      provider: fake_provider,
      effective_model: "gpt-4.1",
      context_window: stub(value: 8192, source: :env),
      max_response_tokens: stub(value: 1024, source: :env),
      max_items_per_call: stub(value: 10, source: :env)
    ))

    perform_enqueued_jobs { LlmSmokeTestJob.perform_later(@family.id) }

    result = Provider::LlmSmokeTest.current(@family)
    assert result.failed?
    assert_match(/401/, result.error)
    assert_no_match(/sk-leaked/, result.error)
  end
end