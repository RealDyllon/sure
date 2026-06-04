class WiseItem::SyncCompleteEvent
  attr_reader :wise_item

  def initialize(wise_item)
    @wise_item = wise_item
  end

  def broadcast
    wise_item.accounts.each(&:broadcast_sync_complete)

    wise_item.broadcast_replace_to(
      wise_item.family,
      target: "wise_item_#{wise_item.id}",
      partial: "wise_items/wise_item",
      locals: { wise_item: wise_item }
    )

    wise_item.family.broadcast_sync_complete
  end
end
