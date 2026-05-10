class AutoCategorizationSuggestion < ApplicationRecord
  self.table_name = "auto_categorization_suggestions"

  belongs_to :run,
             class_name: "AutoCategorizationRun",
             foreign_key: :auto_categorization_run_id,
             inverse_of: :suggestions
  belongs_to :run_transaction,
             class_name: "AutoCategorizationRunTransaction",
             foreign_key: :auto_categorization_run_transaction_id,
             inverse_of: :suggestion
  belongs_to :suggested_category, class_name: "Category", optional: true
  belongs_to :selected_category, class_name: "Category", optional: true

  enum :status, {
    pending_generation: "pending_generation",
    suggested: "suggested",
    needs_review: "needs_review",
    applied: "applied",
    skipped: "skipped",
    unchanged: "unchanged",
    failed: "failed"
  }, validate: true, default: "pending_generation"

  scope :selected, -> { where(selected: true) }

  before_validation :sync_selected_category_name

  validates :run_transaction, presence: true

  def stale_reason
    live_reason = run_transaction.stale_reason
    return live_reason if live_reason.present?
    return "selected category deleted" if selected? && selected_category_id.present? && selected_category.nil?
    return "selected category missing" if selected? && selected_category_id.blank?
    return "selected category outside family" if selected? && selected_category.present? && selected_category.family_id != run.family_id

    nil
  end

  def stale?
    stale_reason.present?
  end

  def apply!
    return false if applied_at.present?

    if stale?
      update!(status: :skipped, error: stale_reason, selected_category_name: selected_category_name.presence || selected_category&.name)
      return false
    end

    transaction = run_transaction.live_transaction
    transaction.update!(category_id: selected_category.id)
    transaction.lock_attr!(:category_id)

    update!(
      status: :applied,
      applied_at: Time.current,
      selected_category_name: selected_category.name,
      error: nil
    )
    true
  rescue => error
    update!(status: :failed, error: AutoCategorization::ErrorSanitizer.call(error))
    raise
  end

  private
    def sync_selected_category_name
      self.selected_category_name = selected_category.name if selected_category.present?
    end
end
