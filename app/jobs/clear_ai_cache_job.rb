class ClearAiCacheJob < ApplicationJob
  queue_as :low_priority

  def perform(family)
    Rails.logger.info("Clearing AI cache for family #{family.id}")

    # Clear AI enrichment data for transactions
    Transaction.clear_ai_cache(family)
    Rails.logger.info("Cleared AI cache for transactions")

    # Clear AI enrichment data for entries
    Entry.clear_ai_cache(family)
    Rails.logger.info("Cleared AI cache for entries")
  end
end
