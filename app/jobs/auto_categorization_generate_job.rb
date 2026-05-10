class AutoCategorizationGenerateJob < ApplicationJob
  queue_as :medium_priority
  sidekiq_options retry: false

  def perform(run)
    return unless run.is_a?(AutoCategorizationRun)
    return if run.complete? || run.empty?
    return unless claim_run!(run)

    AutoCategorization::GenerateSuggestions.call(run:, job_id:)
  end

  private
    def claim_run!(run)
      run.with_lock do
        run.reload
        return false if run.complete? || run.empty?
        return false unless run.processing_progress_job_matches?(job_id)

        next_status = run.family.categories.exists? ? :suggesting_transactions : :suggesting_categories
        retry_count = run.processing_progress.to_h["retry_count"].to_i
        run.update!(status: next_status, error: nil, finished_at: nil)
        run.update_processing_progress!(
          phase: next_status,
          message: run.family.categories.exists? ? "Generating transaction suggestions" : "Generating starter categories",
          current: 0,
          total: run.family.categories.exists? ? run.run_transactions.count : nil,
          job_id: job_id,
          retry_count: retry_count,
          guard_job_id: job_id
        )
      end

      true
    end
end
