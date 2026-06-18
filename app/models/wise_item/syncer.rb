class WiseItem::Syncer
  include SyncStats::Collector

  attr_reader :wise_item

  def initialize(wise_item)
    @wise_item = wise_item
  end

  def perform_sync(sync)
    sync.update!(status_text: "Importing Wise balances...") if sync.respond_to?(:status_text)
    wise_item.import_latest_wise_data

    sync.update!(status_text: "Checking Wise account setup...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: wise_item.wise_balances)

    linked_balances = wise_item.wise_balances.joins(:account_provider)
    if linked_balances.any?
      sync.update!(status_text: "Processing Wise transactions...") if sync.respond_to?(:status_text)
      mark_import_started(sync)
      wise_item.process_accounts

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      wise_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      account_ids = linked_balances.includes(:account_provider).filter_map(&:current_account).map(&:id)
      collect_transaction_stats(sync, account_ids: account_ids, source: "wise")
    end

    collect_health_stats(sync, errors: nil)
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
    # no-op. Sync#perform_post_sync already calls
    # syncable.broadcast_sync_complete, which delegates to
    # WiseItem::SyncCompleteEvent via Syncable#sync_broadcaster.
    # Broadcasting here would fire the event a second time and
    # re-run the family's recurring-transaction identification.
  end
end
