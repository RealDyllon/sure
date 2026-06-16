require "test_helper"

class WiseItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @wise_item = WiseItem.create!(
      family: families(:dylan_family),
      name: "Wise Connection",
      auth_mode: "oauth",
      access_token: "access-token",
      refresh_token: "refresh-token"
    )
  end

  test "syncer updates pending_account_setup based on requires_setup" do
    linked_balance = @wise_item.wise_balances.create!(
      balance_id: "balance-usd",
      profile_id: "profile-1",
      name: "Wise USD",
      currency: "USD",
      balance_type: "STANDARD",
      current_balance: 100
    )
    account = Account.create_and_sync(
      {
        family: @wise_item.family,
        name: "Wise USD",
        balance: 100,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )
    AccountProvider.create!(account: account, provider: linked_balance)

    @wise_item.wise_balances.create!(
      balance_id: "balance-eur",
      profile_id: "profile-1",
      name: "Wise EUR",
      currency: "EUR",
      balance_type: "STANDARD",
      current_balance: 50
    )

    WiseItem::Importer.any_instance.stubs(:import).returns({ success: true, balances: 2, cards: 0 })

    sync = Sync.create!(syncable: @wise_item, status: "pending")
    WiseItem::Syncer.new(@wise_item).perform_sync(sync)

    assert @wise_item.reload.pending_account_setup
  end

  test "syncer clears pending_account_setup when all balances linked" do
    balance = @wise_item.wise_balances.create!(
      balance_id: "balance-usd",
      profile_id: "profile-1",
      name: "Wise USD",
      currency: "USD",
      balance_type: "STANDARD",
      current_balance: 100
    )
    account = Account.create_and_sync(
      {
        family: @wise_item.family,
        name: "Wise USD",
        balance: 100,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )
    AccountProvider.create!(account: account, provider: balance)

    @wise_item.update!(pending_account_setup: true)
    WiseItem::Importer.any_instance.stubs(:import).returns({ success: true, balances: 1, cards: 0 })

    sync = Sync.create!(syncable: @wise_item, status: "pending")
    WiseItem::Syncer.new(@wise_item).perform_sync(sync)

    assert_not @wise_item.reload.pending_account_setup
  end

  test "perform_post_sync broadcasts the wise item partial" do
    WiseItem::SyncCompleteEvent.any_instance.expects(:broadcast).once

    WiseItem::Syncer.new(@wise_item).perform_post_sync
  end
end
