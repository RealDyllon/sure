class StatementImport < PdfImport
  MAX_PROCESSING_RETRIES = 1

  encrypts :statement_pdf_password

  def process_with_ai_later
    job = ProcessStatementImportJob.new(self)
    update_processing_progress!(
      phase: "queued",
      message: I18n.t("imports.progress.default_message", default: "Processing statement"),
      current: 0,
      total: processing_progress.to_h["total"],
      job_id: job.job_id,
      retry_count: processing_progress.to_h["retry_count"].to_i
    )
    job.enqueue
  end

  def process_statement!(progress_callback: nil, guard_job_id: nil)
    result = StatementExtraction::Extractor.new(self).extract(progress_callback: progress_callback)
    persisted_result = false

    with_lock do
      reload
      if processing_progress_job_matches?(guard_job_id)
        update!(
          extracted_data: result.to_h,
          document_type: statement_document_type(result),
          ai_summary: "Extracted #{extracted_activity_count(result.accounts)} activities from #{result.provider.upcase} #{result.file_type.upcase} statement."
        )
        sync_rows_count!
        persisted_result = true
      end
    end

    result if persisted_result
  end

  def import!
    StatementExtraction::Publisher.new(self).publish!
  end

  def csv_uploaded?
    raw_file_str.present?
  end

  def uploaded?
    csv_uploaded? || pdf_uploaded?
  end

  def file_type
    extracted_data&.dig("file_type").presence || (csv_uploaded? ? "csv" : "pdf")
  end

  def provider
    extracted_data&.dig("provider").presence || "unknown"
  end

  def statement_period
    extracted_data&.dig("statement_period") || {}
  end

  def extracted_accounts
    extracted_data&.dig("accounts") || []
  end

  def review_complete?
    extracted_data&.dig("review_confirmed") == true && extracted_accounts.present? && extracted_accounts.all? do |account_payload|
      review = account_payload["review"] || {}
      case review["action"]
      when "match"
        review["account_id"].present? && family.accounts.exists?(id: review["account_id"])
      when "create"
        review["account_name"].present? && review["account_type"].present? && review["currency"].present?
      else
        false
      end
    end
  end

  def update_review_account!(source_id, action:, account_id:, account_type:, account_subtype:, account_name:, currency:)
    updated_accounts = extracted_accounts.map do |account_payload|
      next account_payload unless account_payload["source_id"] == source_id

      account_payload.merge(
        "review" => {
          "action" => action,
          "account_id" => account_id,
          "account_type" => account_type.presence || account_payload["account_type"],
          "account_subtype" => account_subtype.presence || account_payload["subtype"],
          "account_name" => account_name.presence || account_payload["name"],
          "currency" => currency.presence || account_payload["currency"].presence || family.currency
        }
      )
    end

    update!(extracted_data: extracted_data.merge("accounts" => updated_accounts, "review_confirmed" => true))
  end

  def configured?
    uploaded? && extracted_accounts.present?
  end

  def publishable?
    pending? && review_complete?
  end

  def retryable_processing_stall?
    importing? &&
      processing_progress_stale? &&
      processing_progress.to_h["retry_count"].to_i < MAX_PROCESSING_RETRIES
  end

  def retryable_processing?
    return false unless is_a?(StatementImport)
    return false if processing_progress.to_h["retry_count"].to_i >= MAX_PROCESSING_RETRIES

    failed? || retryable_processing_stall?
  end

  def queue_processing_retry!(message:)
    job = nil
    queued = false

    with_lock do
      reload
      if retryable_processing?
        progress = processing_progress.to_h.deep_stringify_keys
        retry_count = progress["retry_count"].to_i + 1
        job = ProcessStatementImportJob.new(self)

        update!(status: :pending, error: nil)
        update_processing_progress!(
          phase: "queued",
          message: message,
          current: 0,
          total: progress["total"],
          job_id: job.job_id,
          retry_count: retry_count
        )
        queued = true
      end
    end

    job.enqueue if queued
    queued
  end

  def processing_progress_job_matches?(job_id)
    return true if job_id.blank?

    progress_job_id = processing_progress.to_h["job_id"]
    progress_job_id.blank? || progress_job_id == job_id
  end

  def requires_csv_workflow?
    false
  end

  def sync_rows_count!
    update_column(:rows_count, extracted_activity_count(extracted_accounts))
  end

  def original_filename
    pdf_file.attached? ? pdf_file.filename.to_s : statement_original_filename.presence || "statement.csv"
  end

  private

    def statement_document_type(result)
      %w[cpf ibkr].include?(result.provider) ? "investment_statement" : "bank_statement"
    end

    def extracted_activity_count(accounts)
      accounts.sum do |account|
        Array(account["transactions"]).size + Array(account["trades"]).size
      end
    end
end
