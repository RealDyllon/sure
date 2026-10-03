class Provider::OpenaiViaCodex < Provider::Openai
  Error = Class.new(Provider::Error)

  CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex".freeze
  MODEL_PREFIX = "openai-codex/".freeze
  DEFAULT_MODEL_SLUGS = %w[gpt-6.1-sol gpt-6-astra gpt-6-sol gpt-6-luna gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5].freeze
  DEFAULT_MODEL = "#{MODEL_PREFIX}#{DEFAULT_MODEL_SLUGS.first}".freeze
  DEFAULT_CONTEXT_WINDOWS = {
    "gpt-6.1-sol" => 272_000,
    "gpt-5.4" => 1_050_000,
    "gpt-5.4-mini" => 400_000,
    "gpt-5.4-nano" => 400_000
  }.freeze
  DEFAULT_MAX_RESPONSE_TOKENS = 128_000

  def self.effective_model
    configured = ENV.fetch("OPENAI_MODEL") { Setting.openai_model }.presence
    return configured if configured&.start_with?(MODEL_PREFIX)

    DEFAULT_MODEL
  end

  def self.configured?
    Auth.new.configured?
  end

  def initialize(auth: Auth.new, client: nil, model: nil)
    @client = client || Client.new(auth: auth)
    @uri_base = CODEX_BASE_URL
    @default_model = normalize_model(model.presence || self.class.effective_model)
  end

  def supports_model?(model)
    model.to_s.start_with?(MODEL_PREFIX)
  end

  def supports_responses_endpoint?
    true
  end

  def context_window
    positive_budget(ENV["LLM_CONTEXT_WINDOW"], Setting.llm_context_window, default_context_window)
  end

  def max_response_tokens
    positive_budget(ENV["LLM_MAX_RESPONSE_TOKENS"], Setting.llm_max_response_tokens, DEFAULT_MAX_RESPONSE_TOKENS)
  end

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    tool_choice: nil,
    conversation_history: [],
    messages: nil,
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil,
    family: nil
  )
    return stream_chat(prompt: prompt, model: model, instructions: instructions, functions: functions, function_results: function_results, tool_choice: tool_choice, messages: messages, streamer: streamer, family: family) if streamer.present?

    generic_chat_response(
      prompt: prompt,
      model: model,
      instructions: instructions,
      functions: functions,
      function_results: function_results,
      tool_choice: tool_choice,
      messages: messages,
      streamer: streamer,
      session_id: session_id,
      user_identifier: user_identifier,
      family: family
    )
  end

  def provider_name
    "OpenAI via Codex"
  end

  def supported_models_description
    slugs = @client.respond_to?(:fetch_model_slugs) ? @client.fetch_model_slugs : DEFAULT_MODEL_SLUGS
    "models: #{slugs.map { |slug| "#{MODEL_PREFIX}#{slug}" }.join(", ")}"
  end

  def custom_provider?
    false
  end

  def supports_pdf_processing?(model: @default_model)
    supports_model?(model)
  end

  private

    def stream_chat(prompt:, model:, instructions:, functions:, function_results:, tool_choice:, messages:, streamer:, family:)
      with_provider_response do
        payload = { model: model, messages: build_generic_messages(prompt: prompt, instructions: instructions, function_results: function_results, messages: messages), tools: build_generic_tools(functions) }
        payload[:tool_choice] = "none" if tool_choice == :none
        result = nil
        usage = nil
        stream = proc do |event|
          chunk = ChatStreamParser.new(event).parsed
          if chunk
            raise Error, "Codex stream did not complete successfully" if chunk.type == "error"
            if chunk.type == "response"
              result = chunk.data
              usage = chunk.usage
            end
            streamer.call(chunk)
          end
        end
        @client.responses.create(parameters: @client.response_parameters(payload).merge(stream: stream))
        raise Error, "Codex stream ended without a completed response" unless result

        record_llm_usage(family: family, model: model, operation: "chat", usage: usage)
        result
      end
    end


    def normalize_model(model)
      model.to_s.start_with?(MODEL_PREFIX) ? model : "#{MODEL_PREFIX}#{model}"
    end

    def default_context_window
      DEFAULT_CONTEXT_WINDOWS.fetch(@default_model.delete_prefix(MODEL_PREFIX), DEFAULT_CONTEXT_WINDOWS.fetch(DEFAULT_MODEL_SLUGS.first))
    end
end
