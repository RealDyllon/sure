module CategoryCleanup
  class GenerateSuggestions
    def self.call(run:, job_id: nil)
      new(run: run, job_id: job_id).call
    end

    def initialize(run:, job_id: nil)
      @run = run
      @job_id = job_id
    end

    def call
      provider = Provider::Registry.default_llm_provider
      raise RunCreator::MissingProviderError, "AI configuration is required" unless provider
      return unless run.processing_progress_job_matches?(job_id)

      response = provider.organize_categories(
        categories: run.category_snapshot,
        model: run.model,
        family: run.family
      )

      raise response.error unless response.success?

      normalized = SuggestionNormalizer.call(suggestions: response.data, run: run)
      persist_suggestions!(normalized)
    rescue => error
      fail_run!(error)
      raise
    end

    private
      attr_reader :run, :job_id

      def persist_suggestions!(normalized)
        run.with_lock do
          run.reload
          return unless run.processing_progress_job_matches?(job_id)

          run.suggestions.destroy_all
          normalized.each do |attrs|
            run.suggestions.create!(attrs)
          end

          if run.suggestions.exists?
            run.update!(status: :reviewing, error: nil)
            run.refresh_counts!
          else
            run.update!(status: :empty, error: nil, finished_at: Time.current)
          end
        end

        run.finish_processing_progress!(
          message: run.suggestions.exists? ? "Category cleanup suggestions ready for review" : "No category cleanup suggestions",
          guard_job_id: job_id
        )
      end

      def fail_run!(error)
        sanitized = AutoCategorization::ErrorSanitizer.call(error)
        if run.fail_processing_progress!(message: sanitized, guard_job_id: job_id)
          run.update!(
            status: :failed,
            error: sanitized,
            metadata: run.metadata.to_h.merge("failed_phase" => run.processing_progress.to_h["phase"]),
            finished_at: Time.current
          )
        end
      end
  end
end
