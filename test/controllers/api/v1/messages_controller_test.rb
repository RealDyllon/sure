# frozen_string_literal: true

require "test_helper"

class Api::V1::MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read write read_write"
    )

    @write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    @chat = chats(:one)
  end

  test "should require authentication" do
    post "/api/v1/chats/#{@chat.id}/messages"
    assert_response :unauthorized
  end

  test "should require AI to be enabled" do
    @user.update!(ai_enabled: false)

    post "/api/v1/chats/#{@chat.id}/messages",
      params: { content: "Hello" },
      headers: bearer_auth_header(@write_token)
    assert_response :forbidden
  end

  test "should create message with write scope" do
    assert_difference "UserMessage.count" do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message", model: "gpt-4" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "Test message", response_body["content"]
    assert_equal "user_message", response_body["type"]
    assert_equal "pending", response_body["ai_response_status"]
  end

  test "should enqueue assistant response job" do
    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message" },
        headers: bearer_auth_header(@write_token)
    end
  end

  test "should retry last user message with one pending assistant job" do
    assert_enqueued_jobs 1, only: AssistantResponseJob do
      post "/api/v1/chats/#{@chat.id}/messages/retry",
        headers: bearer_auth_header(@write_token)
    end

    assert_response :accepted
    response_body = JSON.parse(response.body)
    assert response_body["message_id"].present?
    assert_equal "Retry initiated", response_body["message"]
  end

  test "retry never enqueues an assistant response job with an assistant message as the prompt" do
    last_user_message = @chat.conversation_messages.where(type: "UserMessage").ordered.last

    captured = nil
    AssistantResponseJob.expects(:perform_later).with do |prompt_message, pending_message|
      captured = [ prompt_message, pending_message ]
      true
    end

    post "/api/v1/chats/#{@chat.id}/messages/retry",
      headers: bearer_auth_header(@write_token)

    assert_response :accepted
    assert captured, "retry must enqueue exactly one AssistantResponseJob"
    assert_kind_of UserMessage, captured[0], "API retry must retry the last user message, not an assistant message"
    assert_kind_of AssistantMessage, captured[1]
    assert captured[0].present? && captured[0].id == last_user_message.id
  end

  test "should not retry if no user message exists" do
    empty_chat = Chat.create!(user: @user, title: "empty chat")

    assert_no_enqueued_jobs only: AssistantResponseJob do
      post "/api/v1/chats/#{empty_chat.id}/messages/retry.json",
        headers: bearer_auth_header(@write_token)
    end

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "No user message to retry", response_body["error"]
  end

  test "should not access messages in other user's chat" do
    other_user = users(:family_member)
    other_user.update!(family: families(:empty))
    other_chat = chats(:two)
    other_chat.update!(user: other_user)

    post "/api/v1/chats/#{other_chat.id}/messages",
      params: { content: "Test" },
      headers: bearer_auth_header(@write_token)

    assert_response :not_found
  end

  private

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
