require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @chat = @user.chats.first
  end

  test "can create a message" do
    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_redirected_to chat_path(@chat, thinking: true)
  end

  test "cannot create a message if AI is disabled" do
    @user.update!(ai_enabled: false)

    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_response :forbidden
  end

  test "creating a message enqueues exactly one assistant response job, not duplicates" do
    assert_enqueued_jobs 1, only: AssistantResponseJob do
      post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }
    end

    assert_redirected_to chat_path(@chat, thinking: true)
  end

  test "web retry enqueues exactly one assistant response job and clears the chat error" do
    @chat.add_error(StandardError.new("OpenAI API error 503: service unavailable"))
    assert @chat.error.present?

    assert_enqueued_jobs 1, only: AssistantResponseJob do
      post retry_chat_url(@chat)
    end

    assert_redirected_to chat_path(@chat)
    assert_nil @chat.reload.error
  end
end
