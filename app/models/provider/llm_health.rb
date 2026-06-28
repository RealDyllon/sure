# frozen_string_literal: true

# Provider::LlmHealth resolves the runtime health of the selected built-in LLM
# provider and exposes it to views (assistant sidebar + self-hosting AI
# settings) without leaking secrets.
#
# It answers a single question: "given the current settings and environment,
# what provider/model/auth-status/budgets would a new AI request actually use,
# and is the provider constructible?"
#
# Secrets (API keys, OAuth tokens, prompts, account names, raw financial data,
# stack traces, oversized provider payloads) are never exposed by this object.
# Any caller-supplied last error is run through {LlmErrorSanitizer} before it
# is returned via `last_error` / `last_error_message`.
#
# Resolution precedence for budgets mirrors the providers themselves
# (ENV override > persisted setting override > provider/model default) but this
# object only reports the resolved value and its source — it does not perform
# provider calls.
class Provider::LlmHealth
  Budget = Struct.new(:value, :source, keyword_init: true)

  attr_reader :provider_key, :provider, :effective_model, :unavailable_reason

  def self.for_family(family)
    new(family)
  end

  def initialize(family)
    @family = family
    @provider_key = resolve_provider_key
    @provider = Provider::Registry.for_concept(:llm).providers.first
    @effective_model = resolve_effective_model
    resolve_unavailability
  end

  def available?
    @provider.present?
  end

  def configured?
    available?
  end

  def auth_configured?
    return true if available?

    # When the provider object is nil, treat an auth/config gap as NOT
    # configured. The registry returns nil for the OpenAI path when the access
    # token is absent and for Codex when Auth#configured? is false.
    @unavailable_reason != :auth_config_missing
  end

  def context_window
    @context_window ||= resolve_budget(:context_window)
  end

  def max_response_tokens
    @max_response_tokens ||= resolve_budget(:max_response_tokens)
  end

  def max_items_per_call
    @max_items_per_call ||= resolve_budget(:max_items_per_call)
  end

  # Returns a sanitized last provider error for the given chat, or nil when
  # the chat has no stored error. The returned object exposes a classified
  # user-facing message and a sanitized technical message.
  def last_error(chat)
    return nil if chat.nil? || chat.technical_error_message.blank?

    LastError.new(
      message: chat.presentable_error_message,
      technical_message: LlmErrorSanitizer.sanitize(chat.technical_error_message.to_s)
    )
  end

  def provider_name
    return @provider.provider_name if available?

    provider_key.to_s
  end

  def settings_path
    Rails.application.routes.url_helpers.settings_hosting_path(anchor: "openai")
  end

  private

    attr_reader :family

    LastError = Struct.new(:message, :technical_message, keyword_init: true)

    def resolve_provider_key
      Provider::Registry.send(:default_llm_provider_key)
    rescue NoMethodError
      nil
    end

    def resolve_effective_model
      Provider::Registry.default_llm_model
    rescue StandardError
      nil
    end

    def resolve_unavailability
      return if available?

      @unavailable_reason =
        if codex_selected_without_auth?
          :codex_auth_missing_from_worker
        else
          :auth_config_missing
        end
    end

    def codex_selected_without_auth?
      provider_key == :codex && !Provider::OpenaiViaCodex.configured?
    end

    # Resolves a single budget dimension. Reports both the effective value and
    # its source so the UI can mark ENV-backed fields non-editable. Falls back
    # to nil when the provider can't be constructed (unavailable) or the
    # requested budget reader is missing.
    def resolve_budget(dimension)
      return Budget.new(value: nil, source: :unavailable) unless available?

      value = @provider.public_send(dimension)
      source =
        case budget_env_for(dimension)
        when ->(env) { env.to_s.strip.to_i.positive? }
          :env
        else
          setting_or_provider_default_source(dimension)
        end

      Budget.new(value: value, source: source)
    end

    def budget_env_for(dimension)
      case dimension
      when :context_window then ENV["LLM_CONTEXT_WINDOW"]
      when :max_response_tokens then ENV["LLM_MAX_RESPONSE_TOKENS"]
      when :max_items_per_call then ENV["LLM_MAX_ITEMS_PER_CALL"]
      end
    end

    def setting_or_provider_default_source(dimension)
      if persisted_setting_present_for?(dimension)
        :setting
      else
        :provider_default
      end
    end

    def persisted_setting_present_for?(dimension)
      case dimension
      when :context_window then Setting.llm_context_window.to_i.positive?
      when :max_response_tokens then Setting.llm_max_response_tokens.to_i.positive?
      when :max_items_per_call then Setting.llm_max_items_per_call.to_i.positive?
      else false
      end
    end
end