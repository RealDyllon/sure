require "test_helper"

# Regression coverage for OpenSpec `ai-provider-reliability`:
# "Failed assistant history is excluded" — a previous assistant response that
# failed or only partially streamed before failure must NOT appear in the
# conversation history sent to the LLM on subsequent turns.
class Assistant::ResponderHistoryTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:one)
  end

  test "excludes failed assistant messages from provider conversation history" do
    complete_user = @chat.conversation_messages.where(type: "UserMessage").ordered.first
    complete_assistant = @chat.conversation_messages.where(type: "AssistantMessage", status: "complete").ordered.first

    # The most recent assistant turn failed partway through streaming.
    failed_assistant = @chat.messages.create!(
      type: "AssistantMessage",
      content: "partial streamed output",
      ai_model: complete_user.ai_model,
      status: "failed"
    )

    # A fresh retry creates a new pending user message turn.
    new_user = @chat.messages.create!(
      type: "UserMessage",
      content: "try again",
      ai_model: complete_user.ai_model
    )

    captured_messages = nil
    fake_llm = CapturingLLM.new { |messages:| captured_messages = messages }

    responder = Assistant::Responder.new(
      message: new_user,
      instructions: "be brief",
      function_tool_caller: stub(function_definitions: [], fulfill_requests: []),
      llm: fake_llm
    )

    responder.respond

    assert captured_messages, "provider should have received conversation history"
    roles_and_content = captured_messages.map { |m| [ m[:role] || m["role"], m[:content] || m["content"] ] }

    # The failed partial assistant message must not appear in history.
    assert_not_includes roles_and_content, [ "assistant", "partial streamed output" ],
      "failed/partial assistant messages must be excluded from provider history"

    # Complete assistant messages should still be present.
    assert_includes roles_and_content.map(&:last), complete_assistant.content
  end

  private

    # A minimal fake LLM that captures the conversation history handed to the
    # provider and returns a successful non-streaming response. Streamer is
    # not invoked here because we exercise the synchronous path.
    class CapturingLLM
      def initialize(&block)
        @block = block
      end

      def chat_response(_prompt, messages:, **)
        @block.call(messages: messages)
        result = Object.new
        result.define_singleton_method(:success?) { true }
        response = Object.new
        response.define_singleton_method(:id) { "resp_test" }
        response.define_singleton_method(:function_requests) { [] }
        result.define_singleton_method(:data) { response }
        result
      end
    end
end