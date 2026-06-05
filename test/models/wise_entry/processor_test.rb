require "test_helper"

class WiseEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    family = families(:dylan_family)
    @wise_item = WiseItem.create!(
      family: family,
      name: "Wise Connection",
      auth_mode: "oauth",
      access_token: "access-token",
      refresh_token: "refresh-token"
    )
    @wise_balance = @wise_item.wise_balances.create!(
      balance_id: "balance-sgd",
      name: "Wise SGD",
      currency: "SGD",
      balance_type: "STANDARD",
      current_balance: 100
    )
    @account = Account.create_and_sync(
      {
        family: family,
        name: "Wise SGD",
        balance: 100,
        currency: "SGD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )
    AccountProvider.create!(account: @account, provider: @wise_balance)
  end

  test "maps positive Wise movement to Sure inflow" do
    entry = WiseEntry::Processor.new(
      {
        id: "txn-credit",
        date: "2026-06-01T10:00:00Z",
        amount: { value: "25.00", currency: "SGD" },
        type: "CREDIT",
        details: { description: "Example Wise top up" }
      },
      wise_balance: @wise_balance
    ).process

    assert_equal BigDecimal("-25.0"), entry.amount
    assert_equal "wise", entry.source
    assert_equal "Example Wise top up", entry.name
    assert_equal "balance-sgd", entry.transaction.extra.dig("wise", "balance_id")
    assert_equal "CREDIT", entry.transaction.extra.dig("wise", "transaction_type")
  end

  test "maps negative Wise movement to Sure outflow and avoids duplicates" do
    payload = {
      id: "txn-card",
      date: "2026-06-02",
      amount: { value: "-7.50", currency: "SGD" },
      type: "CARD",
      details: {
        description: "Example merchant",
        cardLastFourDigits: "4242",
        cardId: "card-1"
      }
    }

    assert_difference -> { @account.entries.where(source: "wise").count }, 1 do
      WiseEntry::Processor.new(payload, wise_balance: @wise_balance).process
    end

    assert_no_difference -> { @account.entries.where(source: "wise").count } do
      WiseEntry::Processor.new(payload, wise_balance: @wise_balance).process
    end

    entry = @account.entries.find_by!(external_id: "wise_balance-sgd_txn-card")
    assert_equal BigDecimal("7.5"), entry.amount
    assert_equal "4242", entry.transaction.extra.dig("wise", "card_last_four")
    assert_equal "card-1", entry.transaction.extra.dig("wise", "card_id")
  end
end
