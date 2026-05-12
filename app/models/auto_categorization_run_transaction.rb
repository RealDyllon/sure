class AutoCategorizationRunTransaction < ApplicationRecord
  self.table_name = "auto_categorization_run_transactions"

  belongs_to :run,
             class_name: "AutoCategorizationRun",
             foreign_key: :auto_categorization_run_id,
             inverse_of: :run_transactions
  belongs_to :entry, optional: true
  belongs_to :live_transaction,
             class_name: "Transaction",
             foreign_key: :transaction_id,
             optional: true
  belongs_to :account, optional: true

  has_one :suggestion,
          class_name: "AutoCategorizationSuggestion",
          dependent: :destroy,
          inverse_of: :run_transaction

  enum :status, {
    pending_generation: "pending_generation",
    generated: "generated",
    skipped: "skipped",
    failed: "failed"
  }, validate: true, default: "pending_generation"

  validates :snapshot, presence: true
  validates :captured_at, presence: true

  def to_llm_input
    snapshot.to_h.deep_symbolize_keys.merge(id: id)
  end

  def stale_reason
    return "transaction deleted" unless live_transaction
    return "entry deleted" unless entry
    return "account deleted" unless account
    return "account hidden" unless account.status.in?(%w[draft active])
    return "account inaccessible" unless account_accessible?
    return "entry excluded" if entry.excluded?
    return "split parent" if entry.split_parent?
    return "already categorized" if live_transaction.category_id.present?
    return "transfer transaction" if live_transaction.transfer?
    return "category locked" unless live_transaction.enrichable?(:category_id)

    nil
  end

  def stale?
    stale_reason.present?
  end

  private
    def account_accessible?
      return true unless run.user

      Account.annotatable_by(run.user).where(id: account_id).exists?
    end
end
