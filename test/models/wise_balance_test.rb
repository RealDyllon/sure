require "test_helper"

class WiseBalanceTest < ActiveSupport::TestCase
  setup do
    @wise_item = WiseItem.create!(
      family: families(:dylan_family),
      name: "Wise Connection",
      auth_mode: "oauth",
      access_token: "access-token",
      refresh_token: "refresh-token"
    )
  end

  test "upserts standard Wise balance snapshot" do
    balance = @wise_item.wise_balances.find_or_initialize_by(balance_id: "balance-sgd")
    balance.upsert_wise_snapshot!(
      id: "balance-sgd",
      type: "STANDARD",
      currency: "sgd",
      amount: { value: "123.45", currency: "SGD" },
      cashAmount: { value: "126.90", currency: "SGD" },
      reservedAmount: { value: "3.45", currency: "SGD" }
    )

    assert_equal "Wise SGD", balance.name
    assert_equal "SGD", balance.currency
    assert_equal "STANDARD", balance.balance_type
    assert_equal BigDecimal("126.90"), balance.current_balance
    assert_equal BigDecimal("123.45"), balance.available_balance
    assert_equal "balance-sgd", balance.balance_id
  end

  test "ensures account provider link" do
    balance = @wise_item.wise_balances.create!(
      balance_id: "balance-usd",
      name: "Wise USD",
      currency: "USD",
      balance_type: "STANDARD",
      current_balance: 10
    )
    account = Account.create_and_sync(
      {
        family: @wise_item.family,
        name: "Wise USD",
        balance: 10,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )
    AccountProvider.create!(account: account, provider: balance)

    assert_equal account, balance.current_account
    assert_equal balance.account_provider, balance.ensure_account_provider!
  end

  test "persists skipped setup state" do
    balance = @wise_item.wise_balances.create!(
      balance_id: "balance-eur",
      name: "Wise EUR",
      currency: "EUR",
      balance_type: "STANDARD",
      current_balance: 100
    )

    assert_difference -> { @wise_item.wise_balances.requires_setup.count }, -1 do
      balance.mark_skipped!
    end
    assert balance.reload.skipped?

    balance.clear_skipped!

    refute balance.reload.skipped?
  end
end
