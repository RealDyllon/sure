class ProcessStatementImportJob < ApplicationJob
  queue_as :medium_priority
  sidekiq_options retry: false

  def perform(statement_import)
    return unless statement_import.is_a?(StatementImport)
    return unless statement_import.update_processing_progress!(job_id: job_id, phase: "extracting")
    raise Import::MappingError unless statement_import.manageable_by?(statement_import.initiating_user)

    result = StatementExtraction::Extractor.new(statement_import).extract(progress_callback: ->(**event) { statement_import.update_processing_progress!(job_id: job_id, **event) })
    activity_count = result.accounts.sum { |account| Array(account["transactions"]).size + Array(account["trades"]).size }
    raise Import::MaxRowCountExceededError if activity_count > statement_import.max_row_count
    statement_import.with_lock do
      return unless statement_import.processing_progress["job_id"] == job_id && !statement_import.data_committed?
      statement_import.update!(extracted_data: result.to_h, rows_count: result.accounts.sum { |account| Array(account["transactions"]).size + Array(account["trades"]).size }, raw_file_str: nil, status: :pending, statement_pdf_password: nil, processing_progress: statement_import.processing_progress.merge("phase" => "ready", "percent" => 100))
    end
  rescue StandardError => error
    statement_import.with_lock do
      if statement_import.processing_progress["job_id"] == job_id && !statement_import.data_committed?
        statement_import.update!(status: :failed, statement_pdf_password: nil, error: "Statement extraction failed (#{error.class.name}). Check the file, password, and AI settings.", processing_progress: statement_import.processing_progress.merge("phase" => "failed"))
      end
    end
  end
end
