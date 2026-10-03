class StatementImportsController < ApplicationController
  before_action :require_manager
  before_action :set_import, except: [ :new, :create ]

  def new
  end

  def create
    file = params.require(:statement_import)[:file]
    raise AccountStatement::InvalidUploadError unless file && %w[.csv .pdf].include?(File.extname(file.original_filename).downcase)
    statement = AccountStatement.create_from_upload!(family: Current.family, account: nil, file: file)
    import = Current.family.imports.create!(type: "StatementImport", account_statement: statement, initiating_user: Current.user, statement_pdf_password: params.dig(:statement_import, :password).presence)
    import.process_with_ai_later
    redirect_to statement_import_path(import)
  rescue AccountStatement::DuplicateUploadError => error
    existing = error.statement.statement_imports.find_by(initiating_user: Current.user)
    existing ? redirect_to(statement_import_path(existing)) : redirect_to(new_statement_import_path, alert: t("statement_imports.duplicate"))
  rescue AccountStatement::InvalidUploadError, ActiveRecord::RecordInvalid
    redirect_to new_statement_import_path, alert: t("statement_imports.invalid_file")
  end

  def show
    @accounts = @import.authorized_accounts.visible
  end

  def update
    reviews = params.require(:reviews).to_unsafe_h
    @import.save_review!(reviews)
    redirect_to statement_import_path(@import)
  end

  def publish
    @import.publish_later
    redirect_to statement_import_path(@import)
  rescue Import::MappingError
    redirect_to statement_import_path(@import), alert: t("statement_imports.review_required")
  end

  def retry_processing
    @import.with_lock do
      updated = Time.zone.parse(@import.processing_progress["updated_at"].to_s) rescue nil
      if @import.failed? && !@import.data_committed? || @import.importing? && updated && updated < 5.minutes.ago && !@import.data_committed?
        @import.update!(status: :pending, extracted_data: {}, statement_pdf_password: params[:password].presence)
        @import.process_with_ai_later
      end
    end
    redirect_to statement_import_path(@import)
  end

  def revert
    @import.revert_later
    redirect_to statement_import_path(@import)
  end

  private
    def require_manager
      raise ActiveRecord::RecordNotFound unless AccountStatement.statement_manager?(Current.user)
    end

    def set_import
      @import = Current.family.imports.where(type: "StatementImport").find(params[:id])
      raise ActiveRecord::RecordNotFound unless @import.manageable_by?(Current.user)
    end
end
