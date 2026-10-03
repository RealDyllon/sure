class StatementImport < Import
  belongs_to :account_statement
  belongs_to :initiating_user, class_name: "User"
  has_many :statement_import_accounts, dependent: :destroy
  encrypts :statement_pdf_password
  validate :source_belongs_to_family

  def authorized_accounts
    return Account.none unless initiating_user && initiating_user.family_id == family_id

    scope = initiating_user.accessible_accounts
    scope.where(id: scope.select { |candidate| candidate.permission_for(initiating_user).in?([ :owner, :full_control ]) }.map(&:id))
  end

  def manageable_by?(user)
    user && user.id == initiating_user_id && user.family_id == family_id && AccountStatement.statement_manager?(user) && statement_import_accounts.all? { |link| authorized_accounts.exists?(id: link.account_id) }
  end

  def extracted_accounts = extracted_data.to_h.fetch("accounts", [])
  def provider = extracted_data.to_h.fetch("provider", "unknown")
  def file_type = account_statement.pdf? ? "pdf" : "csv"
  def statement_period = extracted_data.to_h.fetch("statement_period", {})
  def original_filename = account_statement.filename
  def csv_uploaded? = account_statement&.original_file&.attached? && file_type == "csv"
  def pdf_uploaded? = account_statement&.original_file&.attached? && file_type == "pdf"
  def uploaded? = csv_uploaded? || pdf_uploaded?
  def pdf_file_content = account_statement.original_file.download
  def requires_csv_workflow? = false
  def column_keys = []
  def configured? = extracted_accounts.present?
  def configured_for_status_detail? = configured?
  def data_committed? = publication_journal["published"] == true
  def cleaned? = review_complete?
  def publishable? = pending? && review_complete? && !data_committed?
  def revertable? = data_committed? && (complete? || revert_failed?)

  def review_complete?
    return false unless extracted_data.to_h["review_confirmed"] && extracted_accounts.present?
    return false unless manageable_by?(initiating_user)

    extracted_accounts.all? do |payload|
      review = payload.fetch("review", {})
      if review["action"] == "match"
        candidate = authorized_accounts.find_by(id: review["account_id"])
        candidate && (payload["currency"].blank? || payload["currency"] == candidate.currency)
      elsif review["action"] == "create"
        review["account_name"].present? && Accountable::TYPES.include?(review["account_type"]) && Money::Currency.all_instances.any? { |currency| currency.iso_code == review["currency"] }
      else
        false
      end
    end
  end

  def save_review!(reviews)
    with_lock(requires_new: true) do
      raise MappingError, "Import is no longer editable" unless pending? && !data_committed?
      payloads = extracted_accounts.map do |payload|
        review = reviews.fetch(payload["source_id"], {}).stringify_keys.slice("action", "account_id", "account_name", "account_type", "account_subtype", "currency")
        payload.merge("review" => review)
      end
      update!(extracted_data: extracted_data.merge("accounts" => payloads, "review_confirmed" => true))
    end
  end

  def process_with_ai_later
    with_lock(requires_new: true) do
      return false unless uploaded? && !data_committed? && (pending? || failed?)
      return false if configured? && pending?

      job = ProcessStatementImportJob.new(self)
      update!(status: :importing, error: nil, processing_progress: { "job_id" => job.job_id, "phase" => "queued", "percent" => 0, "updated_at" => Time.current.iso8601 })
      job.enqueue
    end
  end

  def update_processing_progress!(job_id:, **event)
    with_lock(requires_new: true) do
      return false unless processing_progress["job_id"] == job_id && importing? && !data_committed?

      update!(processing_progress: processing_progress.merge(event.stringify_keys).merge("updated_at" => Time.current.iso8601))
    end
  end

  def publish_later
    with_lock(requires_new: true) do
      raise MappingError, "Review every account before publishing" unless publishable?
      update!(status: :importing)
      ImportJob.perform_later(self)
    end
  end

  def publish
    with_lock(requires_new: true) do
      return if data_committed?
      raise MappingError, "Account access changed or review is incomplete" unless review_complete?
      StatementExtraction::Publisher.new(self).publish!
      update!(status: :complete, statement_pdf_password: nil)
    end
    family.sync_later
  rescue StandardError => error
    reload
    update!(status: :failed, error: "Statement publication failed (#{error.class.name}). Review account access and statement values.")
  end

  def revert
    with_lock(requires_new: true) do
      return unless data_committed?
      StatementExtraction::Publisher.new(self).revert!
      update!(status: :pending, publication_journal: {}, extracted_data: extracted_data.merge("review_confirmed" => false))
    end
    family.sync_later
  rescue StandardError => error
    reload
    update!(status: :revert_failed, error: "Statement reversal failed (#{error.class.name}). Later account changes may require manual review.")
  end

  private
    def source_belongs_to_family
      errors.add(:account_statement, :invalid) if account_statement && account_statement.family_id != family_id
      errors.add(:initiating_user, :invalid) if initiating_user && initiating_user.family_id != family_id
    end
end
