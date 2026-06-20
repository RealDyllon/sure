require "test_helper"

class WiseBalance::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @wise_item = @family.wise_items.create!(
      name: "Wise Connection",
      auth_mode: "oauth",
      access_token: "example-access-token",
      refresh_token: "example-refresh-token"
    )
    @wise_balance = @wise_item.wise_balances.create!(
      balance_id: "balance-sgd",
      profile_id: "100",
      name: "Wise SGD",
      currency: "SGD",
      balance_type: "STANDARD",
      current_balance: 100
    )
    @account = Account.create_and_sync(
      {
        family: @family,
        name: "Wise SGD",
        balance: 0,
        currency: "SGD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )
    AccountProvider.create!(account: @account, provider: @wise_balance)
  end

  test "updates linked account balance, cash_balance, and currency" do
    @wise_balance.update!(current_balance: 250.0, currency: "SGD")
    @account.update!(balance: 100, cash_balance: 100, currency: "USD")

    WiseBalance::Processor.new(@wise_balance).process

    @account.reload
    assert_equal BigDecimal("250"), @account.balance
    assert_equal BigDecimal("250"), @account.cash_balance
    assert_equal "SGD", @account.currency
  end

  test "is a no-op when balance has no linked account" do
    orphan = @wise_item.wise_balances.create!(
      balance_id: "orphan",
      profile_id: "100",
      name: "Orphan",
      currency: "SGD",
      balance_type: "STANDARD"
    )

    WiseBalance::Processor.new(orphan).process
    # No exception, no state change
    assert_nil orphan.current_account
  end

  test "imports transactions for linked accounts" do
    @wise_balance.update!(
      raw_transactions_payload: [
        { id: "txn-1", amount: { value: "5.00", currency: "SGD" }, date: "2024-01-15T10:00:00Z",
          details: { description: "Processor test" } }
      ]
    )

    WiseEntry::Processor.any_instance.expects(:process).once

    WiseBalance::Processor.new(@wise_balance).process
  end
end
