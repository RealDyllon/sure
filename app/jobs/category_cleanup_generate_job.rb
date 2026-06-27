class CategoryCleanupGenerateJob < ApplicationJob
  queue_as :medium_priority
  sidekiq_options retry: false

  def perform(run)
    return unless run.is_a?(CategoryCleanupRun)
    return if run.complete? || run.empty?
    return unless claim_run!(run)

    CategoryCleanup::GenerateSuggestions.call(run: run, job_id: job_id)
  end

  private
    def claim_run!(run)
      run.with_lock do
        run.reload
        return false if run.complete? || run.empty?
        # Reject the claim if the run has already moved past generating. This
        # guards against a worker restart after the previous job instance
        # completed generation and transitioned the run to :reviewing but
        # before Sidekiq could ack the job. Without this check, the replayed
        # job would re-flip the run to :generating and
        # GenerateSuggestions#persist_suggestions! would delete and recreate
        # suggestions, silently destroying any review edits the user already
        # made in :reviewing.
        return false unless run.generating?
        return false unless run.processing_progress_job_matches?(job_id)

        retry_count = run.processing_progress.to_h["retry_count"].to_i
        run.update!(status: :generating, error: nil, finished_at: nil)
        run.update_processing_progress!(
          phase: :generating,
          message: "Generating category cleanup suggestions",
          current: 0,
          total: run.category_snapshot.size,
          job_id: job_id,
          retry_count: retry_count,
          guard_job_id: job_id
        )
      end

      true
    end
end
