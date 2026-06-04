module WiseItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    results = []

    wise_balances.find_each do |wise_balance|
      links = AccountProvider.where(provider_type: "WiseBalance", provider_id: wise_balance.id).to_a
      link_ids = links.map(&:id)
      result = {
        wise_balance_id: wise_balance.id,
        name: wise_balance.name,
        provider_link_ids: link_ids
      }
      results << result

      next if dry_run

      ActiveRecord::Base.transaction do
        Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil) if link_ids.any?
        links.each(&:destroy!)
      end
    rescue => e
      Rails.logger.warn("WiseItem Unlinker: failed to unlink balance #{wise_balance.id}: #{e.class} - #{e.message}")
      result[:error] = e.message if result
    end

    results
  end
end
