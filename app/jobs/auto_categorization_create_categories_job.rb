class AutoCategorizationCreateCategoriesJob < ApplicationJob
  queue_as :medium_priority
  sidekiq_options retry: false

  def perform(run)
    return unless run.is_a?(AutoCategorizationRun)
    return unless claim_run!(run)

    AutoCategorization::CreateCategories.call(run:, job_id:)
  end

  private
    def claim_run!(run)
      run.with_lock do
        run.reload
        return false unless run.processing_progress_job_matches?(job_id)
        return false unless run.creating_categories?

        retry_count = run.processing_progress.to_h["retry_count"].to_i
        run.update_processing_progress!(
          phase: :creating_categories,
          message: "Creating reviewed categories",
          current: 0,
          total: run.category_suggestions.selected.valid_for_creation.count,
          job_id: job_id,
          retry_count: retry_count,
          guard_job_id: job_id
        )
      end

      true
    end
end
