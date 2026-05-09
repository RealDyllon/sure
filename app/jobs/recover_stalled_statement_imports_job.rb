class RecoverStalledStatementImportsJob < ApplicationJob
  queue_as :scheduled

  def perform
    StatementImport.importing.find_each do |statement_import|
      next unless statement_import.retryable_processing_stall?

      statement_import.queue_processing_retry!(
        message: I18n.t("imports.progress.auto_retry_queued", default: "Processing appeared stalled, so we queued one retry.")
      )
    end
  end
end
