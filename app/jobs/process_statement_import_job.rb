class ProcessStatementImportJob < ApplicationJob
  queue_as :medium_priority
  sidekiq_options retry: false

  def perform(statement_import)
    return unless statement_import.is_a?(StatementImport)
    return unless statement_import.uploaded?
    return if statement_import.complete?

    return unless claim_statement_import!(statement_import)

    result = statement_import.process_statement!(
      guard_job_id: job_id,
      progress_callback: ->(**event) {
        statement_import.update_processing_progress!(
          phase: event[:phase].presence || :extracting,
          message: event[:message],
          current: event[:current],
          total: event[:total],
          job_id: job_id,
          guard_job_id: job_id
        )
      }
    )
    return unless result && statement_import.reload.processing_progress_job_matches?(job_id)

    return unless statement_import.finish_processing_progress!(message: "Ready for review", guard_job_id: job_id)

    statement_import.update!(status: :pending, statement_pdf_password: nil)
  rescue StandardError => e
    sanitized = e.message.to_s.truncate(500)
    if statement_import&.persisted?
      if statement_import.fail_processing_progress!(message: sanitized, guard_job_id: job_id)
        statement_import.update!(status: :failed, error: sanitized, statement_pdf_password: nil)
      end
    end
    raise
  end

  private
    def claim_statement_import!(statement_import)
      statement_import.with_lock do
        statement_import.reload
        return false if statement_import.complete?
        return false unless statement_import.processing_progress_job_matches?(job_id)

        retry_count = statement_import.processing_progress.to_h["retry_count"].to_i
        statement_import.update!(status: :importing)
        statement_import.update_processing_progress!(
          phase: :preparing,
          message: "Preparing statement import",
          job_id: job_id,
          retry_count: retry_count,
          guard_job_id: job_id
        )
      end

      true
    end
end
