class RecoverStalledAutoCategorizationRunsJob < ApplicationJob
  queue_as :scheduled

  def perform
    AutoCategorizationRun.active.find_each do |run|
      next unless run.retryable_processing_stall?

      run.queue_retry!(message: "Processing appeared stalled, so we queued one retry.")
    end
  end
end
