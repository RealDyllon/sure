# frozen_string_literal: true

# Cache-backed result state for the admin AI provider smoke test.
#
# Stored under a stable cache key scoped to the family so an admin can see the
# latest run from self-hosting AI settings without a dedicated table. The
# structure is intentionally small: it reports queued/running/succeeded/failed
# plus timestamps, effective provider/model/budgets, and a sanitized error.
#
# No secrets (API keys, OAuth tokens, Codex auth files, prompts, account
# names, raw financial data, or provider payloads) are stored here — only the
# sanitized error string produced by {Provider::LlmHealth::LlmErrorSanitizer}.
class Provider::LlmSmokeTest
  STATUSES = %w[queued running succeeded failed].freeze
  TTL = 24.hours

  Status = Struct.new(:status, :queued_at, :finished_at, :provider, :model,
                      :context_window, :max_response_tokens, :max_items_per_call,
                      :error, keyword_init: true) do
    def queued?
      status == "queued"
    end

    def running?
      status == "running"
    end

    def succeeded?
      status == "succeeded"
    end

    def failed?
      status == "failed"
    end

    def finished?
      succeeded? || failed?
    end
  end

  class << self
    def current(family)
      Rails.cache.read(cache_key(family)) || Status.new(status: nil)
    end

    def record(family, **attributes)
      status = Status.new(**attributes)
      Rails.cache.write(cache_key(family), status, expires_in: TTL)
      status
    end

    def clear(family)
      Rails.cache.delete(cache_key(family))
    end

    def cache_key(family)
      "provider/smoke_test/#{family.id}"
    end
  end
end