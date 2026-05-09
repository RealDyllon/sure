require "test_helper"

class Provider::OpenaiViaCodex::ClientTest < ActiveSupport::TestCase
  test "responses.create strips codex model prefix and sends account header" do
    auth = stub(access_token_and_account_id: [ "access-token", "account-123" ])
    client = Provider::OpenaiViaCodex::Client.new(auth: auth)

    stub_request(:post, "https://chatgpt.com/backend-api/codex/responses")
      .with(
        headers: {
          "Authorization" => "Bearer access-token",
          "ChatGPT-Account-ID" => "account-123",
          "Content-Type" => "application/json"
        },
        body: hash_including(model: "gpt-5.4", input: [ { role: "user", content: "hi" } ])
      )
      .to_return(
        status: 200,
        body: { id: "resp_1", output: [], usage: { input_tokens: 1, output_tokens: 2, total_tokens: 3 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    response = client.responses.create(parameters: {
      model: "openai-codex/gpt-5.4",
      input: [ { role: "user", content: "hi" } ],
      stream: nil
    })

    assert_equal "resp_1", response["id"]
  end

  test "responses.create streams SSE hashes to the supplied callback" do
    auth = stub(access_token_and_account_id: [ "access-token", nil ])
    client = Provider::OpenaiViaCodex::Client.new(auth: auth)
    events = []

    stub_request(:post, "https://chatgpt.com/backend-api/codex/responses")
      .with(body: hash_including(model: "gpt-5.4", stream: true))
      .to_return(
        status: 200,
        body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\n" \
              "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}\n\n" \
              "data: [DONE]\n\n",
        headers: { "Content-Type" => "text/event-stream" }
      )

    result = client.responses.create(parameters: {
      model: "openai-codex/gpt-5.4",
      input: [ { role: "user", content: "hi" } ],
      stream: proc { |event| events << event }
    })

    assert_nil result
    assert_equal [ "response.output_text.delta", "response.completed" ], events.map { |event| event["type"] }
  end

  test "chat translates chat-completions parameters to responses and returns chat shape" do
    auth = stub(access_token_and_account_id: [ "access-token", nil ])
    client = Provider::OpenaiViaCodex::Client.new(auth: auth)

    stub_request(:post, "https://chatgpt.com/backend-api/codex/responses")
      .with(body: hash_including(
        model: "gpt-5.4",
        instructions: "System instructions",
        input: [ { role: "user", content: "Return JSON" } ],
        text: { format: { type: "json_object" } }
      ))
      .to_return(
        status: 200,
        body: {
          id: "resp_1",
          output: [
            { type: "message", content: [ { type: "output_text", text: "{\"ok\":true}" } ] }
          ],
          usage: { input_tokens: 5, output_tokens: 3, total_tokens: 8 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    response = client.chat(parameters: {
      model: "openai-codex/gpt-5.4",
      messages: [
        { role: "system", content: "System instructions" },
        { role: "user", content: "Return JSON" }
      ],
      response_format: { type: "json_object" }
    })

    assert_equal "{\"ok\":true}", response.dig("choices", 0, "message", "content")
    assert_equal 8, response.dig("usage", "total_tokens")
  end

  test "fetch_models falls back when upstream request fails" do
    auth = stub(access_token_and_account_id: [ "access-token", nil ])
    client = Provider::OpenaiViaCodex::Client.new(auth: auth)

    stub_request(:get, "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0")
      .to_return(status: 500, body: "boom")

    assert_equal Provider::OpenaiViaCodex::DEFAULT_MODEL_SLUGS, client.fetch_model_slugs
  end
end
