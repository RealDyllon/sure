class ImportsController < ApplicationController
  include SettingsHelper

  before_action :set_import, only: %i[show update publish destroy revert apply_template retry_processing]

  def update
    if @import.is_a?(StatementImport)
      update_statement_import
      return
    end

    # Handle both pdf_import[account_id] and import[account_id] param formats
    account_id = params.dig(:pdf_import, :account_id) || params.dig(:import, :account_id)

    if account_id.present?
      account = accessible_accounts.find_by(id: account_id)
      unless account
        redirect_back_or_to import_path(@import), alert: t("imports.update.invalid_account", default: "Account not found.")
        return
      end
      @import.update!(account: account)
    end

    redirect_to import_path(@import), notice: t("imports.update.account_saved", default: "Account saved.")
  end

  def publish
    @import.publish_later

    redirect_to import_path(@import), notice: "Your import has started in the background."
  rescue Import::MaxRowCountExceededError
    redirect_back_or_to import_path(@import), alert: "Your import exceeds the maximum row count of #{@import.max_row_count}."
  end

  def index
    @pagy, @imports = pagy(Current.family.imports.where(type: Import::TYPES).ordered, limit: safe_per_page)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.imports"), imports_path ]
    ]
    render layout: "settings"
  end

  def new
    @pending_import = Current.family.imports.ordered.pending.first
    @document_upload_extensions = document_upload_supported_extensions
  end

  def create
    file = import_params[:import_file]

    if file.present? && statement_import_request?
      create_statement_import(file)
      return
    end

    if file.present? && document_upload_request?
      create_document_import(file)
      return
    end

    if file.present? && sure_import_request?
      create_sure_import(file)
      return
    end

    # Handle PDF file uploads - process with AI
    if file.present? && Import::ALLOWED_PDF_MIME_TYPES.include?(file.content_type)
      unless valid_pdf_file?(file)
        redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
        return
      end
      create_pdf_import(file)
      return
    end

    type = params.dig(:import, :type).to_s
    type = "TransactionImport" unless Import::TYPES.include?(type)

    account = accessible_accounts.find_by(id: params.dig(:import, :account_id))
    import = Current.family.imports.create!(
      type: type,
      account: account,
      date_format: Current.family.date_format,
    )

    if file.present?
      if file.size > Import::MAX_CSV_SIZE
        import.destroy
        redirect_to new_import_path, alert: t("imports.create.file_too_large", max_size: Import::MAX_CSV_SIZE / 1.megabyte)
        return
      end

      unless Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)
        import.destroy
        redirect_to new_import_path, alert: t("imports.create.invalid_file_type")
        return
      end

      # Stream reading is not fully applicable here as we store the raw string in the DB,
      # but we have validated size beforehand to prevent memory exhaustion from massive files.
      import.update!(raw_file_str: file.read)

      redirect_to import_configuration_path(import), notice: t("imports.create.csv_uploaded")
    else
      redirect_to import_upload_path(import)
    end
  end

  def show
    unless @import.requires_csv_workflow?
      redirect_to import_upload_path(@import), alert: t("imports.show.finalize_upload") unless @import.uploaded?
      return
    end

    if !@import.uploaded?
      redirect_to import_upload_path(@import), alert: t("imports.show.finalize_upload")
    elsif !@import.publishable?
      redirect_to import_confirm_path(@import), alert: t("imports.show.finalize_mappings")
    end
  end

  def revert
    @import.revert_later
    redirect_to imports_path, notice: "Import is reverting in the background."
  end

  def apply_template
    if @import.suggested_template
      @import.apply_template!(@import.suggested_template)
      redirect_to import_configuration_path(@import), notice: "Template applied."
    else
      redirect_to import_configuration_path(@import), alert: "No template found, please manually configure your import."
    end
  end

  def retry_processing
    unless @import.is_a?(StatementImport)
      redirect_back_or_to import_path(@import), alert: t("imports.retry_processing.unsupported")
      return
    end

    unless queue_statement_processing_retry!(message: t("imports.progress.retry_queued"))
      redirect_back_or_to import_path(@import), alert: t("imports.retry_processing.not_retryable")
      return
    end

    redirect_to import_path(@import), notice: t("imports.retry_processing.started")
  end

  def destroy
    @import.destroy

    redirect_to imports_path, notice: "Your import has been deleted."
  end

  private
    def set_import
      @import = Current.family.imports.includes(:account).find(params[:id])
    end

    def queue_statement_processing_retry!(message:)
      @import.queue_processing_retry!(message: message)
    end

    def import_params
      params.require(:import).permit(:import_file)
    end

    def create_pdf_import(file)
      if file.size > Import::MAX_PDF_SIZE
        redirect_to new_import_path, alert: t("imports.create.pdf_too_large", max_size: Import::MAX_PDF_SIZE / 1.megabyte)
        return
      end

      pdf_import = Current.family.imports.create!(type: "PdfImport")
      pdf_import.pdf_file.attach(file)
      pdf_import.process_with_ai_later

      redirect_to import_path(pdf_import), notice: t("imports.create.pdf_processing")
    end

    def create_statement_import(file)
      statement_import = Current.family.imports.create!(
        type: "StatementImport",
        date_format: "%Y-%m-%d"
      )

      if Import::ALLOWED_PDF_MIME_TYPES.include?(file.content_type) || File.extname(file.original_filename.to_s).downcase == ".pdf"
        unless valid_pdf_file?(file)
          statement_import.destroy
          redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
          return
        end

        if file.size > Import::MAX_PDF_SIZE
          statement_import.destroy
          redirect_to new_import_path, alert: t("imports.create.pdf_too_large", max_size: Import::MAX_PDF_SIZE / 1.megabyte)
          return
        end

        statement_import.statement_pdf_password = params.dig(:import, :statement_pdf_password)
        statement_import.statement_original_filename = file.original_filename.to_s
        statement_import.pdf_file.attach(file)
      elsif Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type) || File.extname(file.original_filename.to_s).downcase == ".csv"
        if file.size > Import::MAX_CSV_SIZE
          statement_import.destroy
          redirect_to new_import_path, alert: t("imports.create.file_too_large", max_size: Import::MAX_CSV_SIZE / 1.megabyte)
          return
        end

        statement_import.statement_original_filename = file.original_filename.to_s
        statement_import.raw_file_str = file.read
      else
        statement_import.destroy
        redirect_to new_import_path, alert: t("imports.create.invalid_statement_file_type", default: "Invalid statement file type. Please upload a PDF or CSV file.")
        return
      end

      statement_import.save!
      statement_import.process_with_ai_later

      redirect_to import_path(statement_import), notice: t("imports.create.statement_processing", default: "Your statement is being processed.")
    end

    def create_document_import(file)
      adapter = VectorStore.adapter
      unless adapter
        redirect_to new_import_path, alert: t("imports.create.document_provider_not_configured")
        return
      end

      if file.size > Import::MAX_PDF_SIZE
        redirect_to new_import_path, alert: t("imports.create.document_too_large", max_size: Import::MAX_PDF_SIZE / 1.megabyte)
        return
      end

      filename = file.original_filename.to_s
      ext = File.extname(filename).downcase
      supported_extensions = adapter.supported_extensions.map(&:downcase)

      unless supported_extensions.include?(ext)
        redirect_to new_import_path, alert: t("imports.create.invalid_document_file_type")
        return
      end

      if ext == ".pdf"
        unless valid_pdf_file?(file)
          redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
          return
        end

        create_pdf_import(file)
        return
      end

      family_document = Current.family.upload_document(
        file_content: file.read,
        filename: filename
      )

      if family_document
        redirect_to new_import_path, notice: t("imports.create.document_uploaded")
      else
        redirect_to new_import_path, alert: t("imports.create.document_upload_failed")
      end
    end

    def document_upload_supported_extensions
      adapter = VectorStore.adapter
      return [] unless adapter

      adapter.supported_extensions.map(&:downcase).uniq.sort
    end

    def document_upload_request?
      params.dig(:import, :type) == "DocumentImport"
    end

    def statement_import_request?
      params.dig(:import, :type) == "StatementImport" || statement_like_file?(params.dig(:import, :import_file))
    end

    def statement_like_file?(file)
      return false unless file.present?

      filename = file.original_filename.to_s.downcase
      extension = File.extname(filename)
      return false unless extension.in?(%w[.pdf .csv])

      statement_provider_filename_tokens.any? do |provider|
        filename.include?(provider)
      end
    end

    def statement_provider_filename_tokens
      %w[
        dbs
        paylah
        uob
        cpf
        ibkr
        interactivebrokers
        interactive-brokers
        interactive_brokers
        interactive\ brokers
      ]
    end

    def sure_import_request?
      params.dig(:import, :type) == "SureImport"
    end

    def create_sure_import(file)
      if file.size > SureImport::MAX_NDJSON_SIZE
        redirect_to new_import_path, alert: t("imports.create.file_too_large", max_size: SureImport::MAX_NDJSON_SIZE / 1.megabyte)
        return
      end

      ext = File.extname(file.original_filename.to_s).downcase
      unless ext.in?(%w[.ndjson .json])
        redirect_to new_import_path, alert: t("imports.create.invalid_ndjson_file_type")
        return
      end

      content = file.read
      file.rewind
      unless SureImport.valid_ndjson_first_line?(content)
        redirect_to new_import_path, alert: t("imports.create.invalid_ndjson_file_type")
        return
      end

      import = Current.family.imports.create!(type: "SureImport")
      import.ndjson_file.attach(
        io: StringIO.new(content),
        filename: file.original_filename,
        content_type: file.content_type
      )
      import.sync_ndjson_rows_count!

      redirect_to import_path(import), notice: t("imports.create.ndjson_uploaded")
    end

    def valid_pdf_file?(file)
      header = file.read(5)
      file.rewind
      header&.start_with?("%PDF-")
    end

    def update_statement_import
      if params.dig(:statement_import, :statement_pdf_password).present?
        @import.update!(
          statement_pdf_password: params.dig(:statement_import, :statement_pdf_password),
          status: :pending,
          error: nil
        )
        @import.process_with_ai_later
        redirect_to import_path(@import), notice: t("imports.create.statement_processing", default: "Your statement is being processed.")
        return
      end

      review_params = params.fetch(:statement_import, {}).fetch(:accounts, {})
      review_params.each_value do |review|
        account = accessible_accounts.find_by(id: review[:account_id]) if review[:account_id].present?
        @import.update_review_account!(
          review[:source_id],
          action: review[:action].presence || (account ? "match" : "create"),
          account_id: account&.id,
          account_type: review[:account_type],
          account_subtype: review[:account_subtype],
          account_name: review[:account_name],
          currency: review[:currency]
        )
      end

      redirect_to import_path(@import), notice: t("imports.update.statement_review_saved", default: "Statement review saved.")
    end
end
