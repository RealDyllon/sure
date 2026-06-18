require "test_helper"

class WiseItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @wise_item = @family.wise_items.create!(
      name: "Wise Connection",
      auth_mode: "oauth",
      access_token: "example-access-token",
      refresh_token: "example-refresh-token"
    )
    @sync = Sync.create!(syncable: @wise_item)
  end

  test "imports balances and stats even when no balances are linked" do
    syncer = WiseItem::Syncer.new(@wise_item)

    @wise_item.wise_balances.create!(
      balance_id: "1001",
      profile_id: "100",
      name: "Wise USD",
      currency: "USD",
      balance_type: "STANDARD"
    )

    WiseItem::Importer.any_instance.stubs(:import).returns({ success: true, balances: 1, cards: 0 })

    syncer.perform_sync(@sync)

    stats = @sync.reload.sync_stats
    assert_equal 1, stats["total_accounts"]
    assert_equal 0, stats["linked_accounts"]
  end

  test "schedules linked-account syncs and collects transaction stats" do
    wise_balance = @wise_item.wise_balances.create!(
      balance_id: "1001",
      profile_id: "100",
      name: "Wise USD",
      currency: "USD",
      balance_type: "STANDARD"
    )
    account = Account.create_and_sync(
      {
        family: @family,
        name: "Wise USD",
        balance: 100,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )
    AccountProvider.create!(account: account, provider: wise_balance)

    WiseItem::Importer.any_instance.stubs(:import).returns({ success: true, balances: 1, cards: 0 })
    WiseBalance::Processor.any_instance.stubs(:process)

    syncer = WiseItem::Syncer.new(@wise_item)
    syncer.perform_sync(@sync)

    stats = @sync.reload.sync_stats
    assert_equal 1, stats["linked_accounts"]
  end
end
