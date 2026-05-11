module AutoCategorization
  class CreateCategories
    def self.call(run:, job_id: nil)
      new(run:, job_id:).call
    end

    def initialize(run:, job_id: nil)
      @run = run
      @job_id = job_id
    end

    def call
      suggestions = run.category_suggestions.selected.valid_for_creation.order(:created_at)
      raise "Select at least one valid category" if suggestions.none?

      total = suggestions.count
      processed = 0

      suggestions.find_each do |suggestion|
        return unless run.reload.processing_progress_job_matches?(job_id)

        run.with_lock do
          run.reload
          return unless run.processing_progress_job_matches?(job_id)

          suggestion.create_category!
        end

        processed += 1
        run.update_processing_progress!(
          phase: :creating_categories,
          message: "Creating reviewed categories",
          current: processed,
          total: total,
          guard_job_id: job_id
        )
      end

      raise "Create at least one category before continuing" if run.family.categories.none?

      return unless run.finish_processing_progress!(message: "Categories created", guard_job_id: job_id)

      run.refresh_counts!
      run.queue_generation!
    rescue => error
      sanitized = ErrorSanitizer.call(error)
      if run.fail_processing_progress!(message: sanitized, guard_job_id: job_id)
        run.update!(
          status: :failed,
          error: sanitized,
          metadata: run.metadata.to_h.merge("failed_phase" => "creating_categories"),
          finished_at: Time.current
        )
      end
      raise
    end

    private
      attr_reader :run, :job_id
  end
end
