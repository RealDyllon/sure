require "test_helper"

class Provider::OpenaiViaCodexTest < ActiveSupport::TestCase
  test "defaults to codex-prefixed model" do
    provider = Provider::OpenaiViaCodex.new(client: stub)

    assert provider.supports_model?("openai-codex/gpt-5.4")
    assert_not provider.supports_model?("gpt-5.4")
    assert_equal "OpenAI via Codex", provider.provider_name
    assert_equal "openai-codex/gpt-6.1-sol", Provider::OpenaiViaCodex.effective_model
  end

  test "usage provider is inferred as openai_codex without cost estimate" do
    assert_equal "openai_codex", LlmUsage.infer_provider("openai-codex/gpt-5.4")
    assert_nil LlmUsage.calculate_cost(model: "openai-codex/gpt-5.4", prompt_tokens: 10, completion_tokens: 10)
  end

  test "budget readers default to advertised Codex model limits" do
    with_env_overrides(
      "LLM_CONTEXT_WINDOW" => nil,
      "LLM_MAX_RESPONSE_TOKENS" => nil,
      "LLM_SYSTEM_PROMPT_RESERVE" => nil
    ) do
      Setting.stubs(:llm_context_window).returns(nil)
      Setting.stubs(:llm_max_response_tokens).returns(nil)

      provider = Provider::OpenaiViaCodex.new(client: stub, model: "openai-codex/gpt-6.1-sol")

      assert_equal 272_000, provider.context_window
      assert_equal 128_000, provider.max_response_tokens
      assert_equal 256, provider.system_prompt_reserve
      assert_equal 272_000 - 128_000 - 256, provider.max_input_tokens
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
  test "streaming emits deltas and returns parsed completed tool calls" do
    auth = stub(access_token_and_account_id: [ "synthetic-token", "synthetic-account" ])
    client = Provider::OpenaiViaCodex::Client.new(auth: auth)
    completed = { "id" => "example", "model" => "gpt-5.4", "usage" => { "input_tokens" => 1, "output_tokens" => 1 }, "output" => [ { "type" => "function_call", "id" => "example-tool", "call_id" => "example-call", "name" => "example_tool", "arguments" => "{}" } ] }
    body = "data: #{ { type: "response.output_text.delta", delta: "Example" }.to_json }\n\n" + "data: #{ { type: "response.completed", response: completed }.to_json }\n\n"
    stub_request(:post, "#{Provider::OpenaiViaCodex::CODEX_BASE_URL}/responses").with do |request|
      data = JSON.parse(request.body)
      data["store"] == false && data["tool_choice"] == "none" && !data.key?("previous_response_id") && !data.key?("max_output_tokens")
    end.to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })
    chunks = []
    provider = Provider::OpenaiViaCodex.new(client: client)
    response = provider.chat_response("Example", model: "openai-codex/gpt-5.4", tool_choice: :none, streamer: ->(chunk) { chunks << chunk })
    assert response.success?, response.error&.message
    assert_equal "output_text", chunks.first.type
    assert_equal "Example", chunks.first.data
    assert_equal "example_tool", response.data.function_requests.first.function_name
  end

  test "tool calls from completed output items survive an empty final response" do
    auth = stub(access_token_and_account_id: [ "synthetic-token", "synthetic-account" ])
    client = Provider::OpenaiViaCodex::Client.new(auth: auth)
    item = { "type" => "function_call", "id" => "example-tool", "call_id" => "example-call", "name" => "example_tool", "arguments" => "{\"status\":\"ok\"}" }
    completed = { "id" => "example", "model" => "gpt-6.1-sol", "output" => [] }
    body = "data: #{ { type: "response.output_item.done", output_index: 0, item: item }.to_json }\n\n" + "data: #{ { type: "response.completed", response: completed }.to_json }\n\n"
    stub_request(:post, "#{Provider::OpenaiViaCodex::CODEX_BASE_URL}/responses").to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })
    provider = Provider::OpenaiViaCodex.new(client: client)
    [ nil, ->(_chunk) { } ].each do |streamer|
      response = provider.chat_response("Example", model: "openai-codex/gpt-6.1-sol", streamer: streamer)
      assert response.success?, response.error&.message
      request = response.data.function_requests.sole
      assert_equal "example_tool", request.function_name
      assert_equal "example-call", request.call_id
      assert_equal "{\"status\":\"ok\"}", request.function_args
    end
  end

  test "Codex is explicitly selected and does not silently fall back without auth" do
    ClimateControl.modify("LLM_PROVIDER" => "codex") do
      Provider::OpenaiViaCodex.stubs(:configured?).returns(false)
      Provider::Registry.expects(:get_provider).never
      assert_nil Provider::Registry.preferred_llm_provider
      assert Chat.default_model.start_with?("openai-codex/")
    end
  end

  test "standard OpenAI endpoints cannot claim Codex model identifiers" do
    provider = Provider::Openai.new("synthetic-token", uri_base: "https://example.test/v1", model: "example")
    assert_not provider.supports_model?("openai-codex/gpt-5.4")
  end
end
