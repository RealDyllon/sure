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
