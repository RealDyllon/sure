require "test_helper"

class ChatTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @assistant = mock
  end

  test "user sees all messages in debug mode" do
    chat = chats(:one)
    with_env_overrides AI_DEBUG_MODE: "true" do
      assert_equal chat.messages.count, chat.conversation_messages.count
    end
  end

  test "user sees assistant and user messages in normal mode" do
    chat = chats(:one)
    assert_equal 3, chat.conversation_messages.count
  end

  test "uses chat-scoped stream targets" do
    first_chat = chats(:one)
    second_chat = chats(:two)

    assert_not_equal "messages", first_chat.messages_target
    assert_not_equal "chat-error", first_chat.error_target
    assert_not_equal first_chat.messages_target, second_chat.messages_target
    assert_not_equal first_chat.error_target, second_chat.error_target
  end

  test "creates with initial message" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: "gpt-4.1")

      assert_equal 2, chat.messages.count
      assert_equal 1, chat.messages.where(type: "UserMessage").count
      assert_equal 1, chat.messages.where(type: "AssistantMessage", status: "pending").count
    end
  end

  test "creates with default model when model is nil" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: nil)

      assert_equal 2, chat.messages.count
      assert_equal Provider::Registry.default_llm_model, chat.messages.find_by!(type: "UserMessage").ai_model
    end
  end

  test "creates with default model when model is empty string" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: "")

      assert_equal 2, chat.messages.count
      assert_equal Provider::Registry.default_llm_model, chat.messages.find_by!(type: "UserMessage").ai_model
    end
  end

  test "creates with configured model when OPENAI_MODEL env is set" do
    prompt = "Test prompt"

    with_env_overrides OPENAI_MODEL: "custom-model" do
      chat = @user.chats.start!(prompt, model: "")

      assert_equal "custom-model", chat.messages.find_by!(type: "UserMessage").ai_model
    end
  end

  test "creates with codex default model when codex provider is selected" do
    prompt = "Test prompt"

    with_env_overrides LLM_PROVIDER: "codex", OPENAI_MODEL: nil do
      chat = @user.chats.start!(prompt, model: "")

      assert_equal "openai-codex/gpt-5.4", chat.messages.find_by!(type: "UserMessage").ai_model
    end
  end

  test "returns nil presentable error message when no error is stored" do
    chat = chats(:one)

    chat.update!(error: nil)

    assert_nil chat.presentable_error_message
  end

  test "surfaces a friendly rate limit error" do
    chat = chats(:one)

    chat.add_error(StandardError.new("OpenAI API error 429: rate limit exceeded"))

    assert_equal I18n.t("chat.errors.rate_limited"), chat.presentable_error_message
    assert_match "429", chat.technical_error_message
  end

  test "surfaces a friendly temporary provider error" do
    chat = chats(:one)

    chat.add_error(StandardError.new("OpenAI API error 503: service unavailable"))

    assert_equal I18n.t("chat.errors.temporarily_unavailable"), chat.presentable_error_message
    assert_match "503", chat.technical_error_message
  end

  test "surfaces a friendly auth configuration error" do
    chat = chats(:one)

    chat.add_error(StandardError.new("OpenAI API error: invalid api key"))

    assert_equal I18n.t("chat.errors.misconfigured"), chat.presentable_error_message
    assert_match "invalid api key", chat.technical_error_message
  end

  test "surfaces a friendly default error for unrecognized errors" do
    chat = chats(:one)

    chat.add_error(StandardError.new("something totally unknown happened"))

    assert_equal I18n.t("chat.errors.default"), chat.presentable_error_message
  end

  test "falls back to a friendly message for legacy serialized errors" do
    chat = chats(:one)

    chat.update!(error: "OpenAI API error 429: rate limit exceeded".to_json)

    assert_equal I18n.t("chat.errors.rate_limited"), chat.presentable_error_message
    assert_equal "OpenAI API error 429: rate limit exceeded", chat.technical_error_message
  end

  test "create with initial message enqueues exactly one assistant response job" do
    assert_enqueued_with(job: AssistantResponseJob) do
      chat = @user.chats.start!("Test prompt", model: "gpt-4.1")

      assert_equal 2, chat.messages.count
    end

    assert_enqueued_jobs 1, only: AssistantResponseJob
  end

  test "retry clears the stale chat error before queuing a replacement response" do
    chat = chats(:one)
    chat.add_error(StandardError.new("OpenAI API error 503: service unavailable"))
    assert chat.present?

    assert chat.error.present?

    pending = nil
    assert_enqueued_jobs 1, only: AssistantResponseJob do
      pending = chat.retry!
    end

    assert_nil chat.error
    assert_kind_of AssistantMessage, pending
    assert pending.pending?
  end

  test "retry retries the last user message even when a failed assistant message follows it" do
    chat = chats(:one)

    # Simulate a partially-streamed failure: a failed assistant message after the last user message
    user_message = chat.conversation_messages.where(type: "UserMessage").ordered.last
    chat.messages.create!(
      type: "AssistantMessage",
      content: "partial response",
      ai_model: user_message.ai_model,
      status: "failed"
    )

    captured = nil
    AssistantResponseJob.expects(:perform_later).with do |prompt_message, pending_message|
      captured = [ prompt_message, pending_message ]
      true
    end

    pending = chat.retry!

    assert captured, "retry should enqueue exactly one assistant response job"
    assert_kind_of UserMessage, captured[0], "retry must enqueue the user message as the prompt, not an assistant message"
    assert_kind_of AssistantMessage, captured[1]
    assert_equal pending, captured[1]
  end

  test "retry returns nil when there is no retryable user message" do
    chat = Chat.create!(user: @user, title: "empty", messages: [])

    assert_nil chat.retry!
  end

  test "provider-unavailable failure surfaces a sanitized user-facing plus technical error" do
    chat = chats(:one)

    with_env_overrides("OPENAI_ACCESS_TOKEN" => nil, "LLM_PROVIDER" => nil, "OPENAI_MODEL" => nil) do
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:openai_model).returns(nil)
      Setting.stubs(:llm_provider).returns("openai")

      user_message = chat.messages.create!(
        type: "UserMessage",
        content: "ask me anything",
        ai_model: "gpt-4.1"
      )

      Assistant::Builtin.for_chat(chat).respond_to(user_message)

      assert chat.error.present?, "an unavailable provider should report a chat error"
      assert chat.presentable_error_message.present?
      assert_match(/provider configured/i, chat.technical_error_message)
      # Sanitization baseline: the technical message must not leak the raw model
      # identifier beyond the provider context and must remain a short string.
      assert_operator chat.technical_error_message.length, :<, 500
    end
  end
end
