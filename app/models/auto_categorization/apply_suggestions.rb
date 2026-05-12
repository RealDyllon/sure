module AutoCategorization
  class ApplySuggestions
    def self.call(run:, job_id: nil)
      new(run:, job_id:).call
    end

    def initialize(run:, job_id: nil)
      @run = run
      @job_id = job_id
    end

    def call
      selected_scope = run.suggestions.selected.order(:created_at)
      total = selected_scope.count
      processed = 0

      return unless mark_unselected_unchanged!

      selected_scope.find_each do |suggestion|
        return unless run.reload.processing_progress_job_matches?(job_id)

        run.with_lock do
          run.reload
          return unless run.processing_progress_job_matches?(job_id)

          suggestion.apply!
        end

        processed += 1
        run.update_processing_progress!(
          phase: :applying,
          message: "Applying reviewed categories",
          current: processed,
          total: total,
          guard_job_id: job_id
        )
      end

      run.with_lock do
        run.reload
        return unless run.processing_progress_job_matches?(job_id)

        run.refresh_counts!
        run.update!(status: :complete, error: nil, finished_at: Time.current)
      end
      run.finish_processing_progress!(message: "Auto-categorization complete", guard_job_id: job_id)
    rescue => error
      sanitized = ErrorSanitizer.call(error)
      if run.fail_processing_progress!(message: sanitized, guard_job_id: job_id)
        run.update!(
          status: :failed,
          error: sanitized,
          metadata: run.metadata.to_h.merge("failed_phase" => "applying"),
          finished_at: Time.current
        )
      end
      raise
    end

    private
      attr_reader :run, :job_id

      def mark_unselected_unchanged!
        run.with_lock do
          run.reload
          return false unless run.processing_progress_job_matches?(job_id)

          run.suggestions.where(selected: false).where.not(status: "unchanged").update_all(
            status: "unchanged",
            updated_at: Time.current
          )
        end

        true
      end
  end
end
