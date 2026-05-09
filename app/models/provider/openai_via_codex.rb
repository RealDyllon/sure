class Provider::OpenaiViaCodex < Provider::Openai
  Error = Class.new(Provider::Error)

  CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex".freeze
  MODEL_PREFIX = "openai-codex/".freeze
  DEFAULT_MODEL_SLUGS = %w[gpt-5.4 gpt-5.4-mini gpt-5.4-nano].freeze
  DEFAULT_MODEL = "#{MODEL_PREFIX}#{DEFAULT_MODEL_SLUGS.first}".freeze

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

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    messages: nil,
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil,
    family: nil
  )
    generic_chat_response(
      prompt: prompt,
      model: model,
      instructions: instructions,
      functions: functions,
      function_results: function_results,
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

    def normalize_model(model)
      model.to_s.start_with?(MODEL_PREFIX) ? model : "#{MODEL_PREFIX}#{model}"
    end
end
