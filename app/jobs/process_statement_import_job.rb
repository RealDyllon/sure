class ProcessStatementImportJob < ApplicationJob
  queue_as :medium_priority

  def perform(statement_import)
    return unless statement_import.is_a?(StatementImport)
    return unless statement_import.uploaded?
    return if statement_import.complete?

    statement_import.update!(status: :importing)
    statement_import.process_statement!
    statement_import.update!(status: :pending, statement_pdf_password: nil)
  rescue StandardError => e
    sanitized = e.message.to_s.truncate(500)
    statement_import.update!(status: :failed, error: sanitized, statement_pdf_password: nil) if statement_import&.persisted?
    raise
  end
end
