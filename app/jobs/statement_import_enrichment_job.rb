class StatementImportEnrichmentJob < ApplicationJob
  BATCH_SIZE = 20

  queue_as :medium_priority

  def perform(statement_import, transaction_ids:)
    ids = Array(transaction_ids).compact_blank
    return if statement_import.blank? || statement_import.family.blank? || ids.blank?

    family = statement_import.family

    ids.each_slice(BATCH_SIZE) do |batch_ids|
      family.auto_detect_transaction_merchants(batch_ids)
      family.auto_categorize_transactions(batch_ids)
    end
  end
end
