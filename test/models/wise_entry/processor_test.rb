require "test_helper"

class WiseEntry::ProcessorTest < ActiveSupport::TestCase
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
        balance: 100,
        currency: "SGD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )
    AccountProvider.create!(account: @account, provider: @wise_balance)
  end

  test "imports a normal Wise transaction" do
    txn = {
      id: "txn-1",
      type: "CREDIT",
      amount: { value: "12.34", currency: "SGD" },
      date: "2024-01-15T10:00:00Z",
      details: { description: "Example merchant" }
    }

    assert_difference -> { @account.entries.count }, 1 do
      WiseEntry::Processor.new(txn, wise_balance: @wise_balance).process
    end

    entry = @account.entries.order(created_at: :desc).first
    assert_equal "Example merchant", entry.name
    assert_equal Date.parse("2024-01-15"), entry.date
    assert_equal(-BigDecimal("12.34"), entry.amount)
    assert_equal "wise", entry.source
    assert_equal "balance-sgd", entry.entryable.extra["wise"]["balance_id"]
  end

  test "flips sign so outflows are negative and inflows positive" do
    [ { value: "100.00", currency: "SGD" }, { value: "-100.00", currency: "SGD" } ].each_with_index do |amount, idx|
      txn = {
        id: "txn-sign-#{idx}",
        type: "CREDIT",
        amount: amount,
        date: "2024-02-01T00:00:00Z",
        details: { description: "Sign flip #{idx}" }
      }

      WiseEntry::Processor.new(txn, wise_balance: @wise_balance).process
    end

    entries = @account.entries.where(name: [ "Sign flip 0", "Sign flip 1" ]).order(:name)
    assert_equal(-BigDecimal("100.00"), entries.find { |e| e.name == "Sign flip 0" }.amount)
    assert_equal BigDecimal("100.00"),  entries.find { |e| e.name == "Sign flip 1" }.amount
  end

  test "falls back to wise_balance currency when amount omits it" do
    txn = {
      id: "txn-fallback",
      type: "DEBIT",
      amount: { value: "9.99" },
      date: "2024-03-01T00:00:00Z",
      details: { description: "Currency fallback" }
    }

    WiseEntry::Processor.new(txn, wise_balance: @wise_balance).process

    entry = @account.entries.find_by(name: "Currency fallback")
    assert_equal "SGD", entry.currency
  end

  test "is a no-op when balance has no linked account" do
    orphan_balance = @wise_item.wise_balances.create!(
      balance_id: "balance-orphan",
      profile_id: "100",
      name: "Orphan",
      currency: "SGD",
      balance_type: "STANDARD"
    )

    assert_no_difference -> { Entry.count } do
      WiseEntry::Processor.new({ id: "x", amount: 1, date: "2024-01-01" }, wise_balance: orphan_balance).process
    end
  end

  test "stores Wise extras under extra['wise']" do
    txn = {
      id: "txn-extras",
      type: "CREDIT",
      amount: { value: "5.00", currency: "SGD" },
      date: "2024-04-01T00:00:00Z",
      referenceNumber: "REF-42",
      details: {
        description: "Extras round-trip",
        cardId: "card-token-1",
        cardLastFourDigits: "4242",
        exchangeRate: 1.34
      }
    }

    WiseEntry::Processor.new(txn, wise_balance: @wise_balance).process

    entry = @account.entries.find_by(name: "Extras round-trip")
    assert_equal "REF-42", entry.entryable.extra["wise"]["statement_reference"]
    assert_equal "card-token-1", entry.entryable.extra["wise"]["card_id"]
    assert_equal "4242", entry.entryable.extra["wise"]["card_last_four"]
    assert_equal 1.34, entry.entryable.extra["wise"]["exchange_rate"]
  end
end
