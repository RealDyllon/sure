# frozen_string_literal: true

# Runs an AI provider smoke test inside the Sidekiq worker runtime so the
# result proves the worker process (not just the web process) can construct the
# selected provider and reach the model.
#
# Enqueued by Settings::HostingsController#enqueue_llm_smoke_test. Records the
# result through {Provider::LlmSmokeTest} (cache-backed). The controller never
# calls the provider directly.
class LlmSmokeTestJob < ApplicationJob
  queue_as :default

  def perform(family_id)
    family = Family.find_by(id: family_id)
    File.write("/tmp/smoke_debug.log", "PERFORM family_id=#{family_id} found=#{!family.nil?}\n", mode: "a")
    return if family.nil?

    health = Provider::LlmHealth.for_family(family)

    unless health.available?
      Provider::LlmSmokeTest.record(
        family,
        status: "failed",
        queued_at: Time.current,
        finished_at: Time.current,
        provider: health.provider_key,
        error: sanitized("Provider unavailable: no configured built-in LLM provider for worker runtime")
      )
      return
    end

    Provider::LlmSmokeTest.record(
      family,
      status: "running",
      queued_at: Time.current,
      provider: health.provider_key,
      model: health.effective_model,
      context_window: health.context_window.value,
      max_response_tokens: health.max_response_tokens.value,
      max_items_per_call: health.max_items_per_call.value
    )

    perform_minimal_request(health, family)
  rescue => e
    Provider::LlmSmokeTest.record(
      family,
      status: "failed",
      queued_at: Time.current,
      finished_at: Time.current,
      provider: health&.provider_key,
      model: health&.effective_model,
      error: sanitized(e.message)
    )
  end

  private

    def perform_minimal_request(health, family)
      provider = health.provider
      # Minimal, cheap request that exercises provider construction + one call
      # in the worker runtime. Uses a tiny prompt and ignores the streamed
      # output; we only care that it succeeds.
      response = provider.chat_response(
        "Reply with the single word: ok",
        model: health.effective_model,
        instructions: "Be extremely brief.",
        messages: nil,
        family: family
      )

      if response&.success?
        Provider::LlmSmokeTest.record(
          family,
          status: "succeeded",
          queued_at: Time.current,
          finished_at: Time.current,
          provider: health.provider_key,
          model: health.effective_model,
          context_window: health.context_window.value,
          max_response_tokens: health.max_response_tokens.value,
          max_items_per_call: health.max_items_per_call.value
        )
      else
        raise response&.error || StandardError.new("Provider returned an unsuccessful response")
      end
    end

    def sanitized(message)
      Provider::LlmHealth::LlmErrorSanitizer.sanitize(message.to_s)
    end
end