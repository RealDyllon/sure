require "test_helper"

class WiseItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @wise_item = @family.wise_items.create!(
      name: "Wise Connection",
      auth_mode: "oauth",
      access_token: "example-access-token",
      refresh_token: "example-refresh-token"
    )
  end

  test "sync_status_summary with no balances" do
    assert_equal I18n.t("wise_items.wise_item.sync_status.no_balances"), @wise_item.sync_status_summary
  end

  test "sync_status_summary with all balances synced (one)" do
    wise_balance = @wise_item.wise_balances.create!(
      balance_id: "1001",
      profile_id: "100",
      name: "Wise USD",
      currency: "USD",
      balance_type: "STANDARD"
    )
    account = Account.create!(
      family: @family,
      name: "Wise USD",
      balance: 100,
      currency: "USD",
      accountable: Depository.create!(subtype: "checking")
    )
    AccountProvider.create!(account: account, provider: wise_balance)

    assert_equal I18n.t("wise_items.wise_item.sync_status.all_synced", count: 1), @wise_item.sync_status_summary
  end

  test "sync_status_summary with all balances synced (multiple)" do
    usd_balance = @wise_item.wise_balances.create!(
      balance_id: "1001",
      profile_id: "100",
      name: "Wise USD",
      currency: "USD",
      balance_type: "STANDARD"
    )
    sgd_balance = @wise_item.wise_balances.create!(
      balance_id: "1002",
      profile_id: "100",
      name: "Wise SGD",
      currency: "SGD",
      balance_type: "STANDARD"
    )

    [ usd_balance, sgd_balance ].each do |balance|
      account = Account.create!(
        family: @family,
        name: "Wise #{balance.currency}",
        balance: 0,
        currency: balance.currency,
        accountable: Depository.create!(subtype: "checking")
      )
      AccountProvider.create!(account: account, provider: balance)
    end

    assert_equal I18n.t("wise_items.wise_item.sync_status.all_synced", count: 2), @wise_item.sync_status_summary
  end

  test "sync_status_summary with partial setup" do
    linked_balance = @wise_item.wise_balances.create!(
      balance_id: "1001",
      profile_id: "100",
      name: "Wise USD",
      currency: "USD",
      balance_type: "STANDARD"
    )
    unlinked_balance = @wise_item.wise_balances.create!(
      balance_id: "1002",
      profile_id: "100",
      name: "Wise SGD",
      currency: "SGD",
      balance_type: "STANDARD"
    )

    account = Account.create!(
      family: @family,
      name: "Wise USD",
      balance: 0,
      currency: "USD",
      accountable: Depository.create!(subtype: "checking")
    )
    AccountProvider.create!(account: account, provider: linked_balance)

    expected = I18n.t(
      "wise_items.wise_item.sync_status.partial_sync",
      linked_count: 1,
      unlinked_count: 1
    )
    assert_equal expected, @wise_item.sync_status_summary
    # sanity-check the unlinked balance is counted as needing setup
    assert_equal 1, @wise_item.unlinked_accounts_count
    assert_includes @wise_item.wise_balances.requires_setup, unlinked_balance
  end
end
