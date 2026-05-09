require "test_helper"

class StatementExtraction::CsvExtractorTest < ActiveSupport::TestCase
  test "extracts DBS transactions and balances from csv" do
    result = StatementExtraction::CsvExtractor.new(
      raw_csv: file_fixture("imports/dbs_statement.csv").read,
      filename: "dbs_statement.csv"
    ).extract

    assert_equal "dbs", result.provider
    assert_equal "csv", result.file_type
    assert_equal 1, result.accounts.size

    account = result.accounts.first
    assert_equal "DBS 00000018", account["name"]
    assert_equal "dbs:00000018", account["source_id"]
    assert_equal "Depository", account["account_type"]
    assert_equal "SGD", account["currency"]
    assert_equal "3945.40", account["closing_balance"]
    assert_equal "2026-04-03", account["balance_date"]
    assert_equal 3, account["transactions"].size

    first = account["transactions"].first
    assert_equal "2026-04-01", first["date"]
    assert_equal "PayNow Transfer", first["name"]
    assert_equal "12.50", first["amount"]
    assert_equal "dbs:00000018:2026-04-01:12.50:PayNow Transfer", first["external_id"]
  end

  test "extracts CPF buckets as separate investment accounts" do
    result = StatementExtraction::CsvExtractor.new(
      raw_csv: file_fixture("imports/cpf_statement.csv").read,
      filename: "cpf_statement.csv"
    ).extract

    assert_equal "cpf", result.provider
    assert_equal 4, result.accounts.size

    ordinary = result.accounts.find { |account| account["source_id"] == "cpf:ordinary" }
    assert_equal "CPF Ordinary Account", ordinary["name"]
    assert_equal "Investment", ordinary["account_type"]
    assert_equal "cpf_ordinary", ordinary["subtype"]
    assert_equal "21002.00", ordinary["closing_balance"]
    assert_equal 1, ordinary["transactions"].size
  end

  test "extracts IBKR activity statement trades cash activity balances and positions" do
    result = StatementExtraction::CsvExtractor.new(
      raw_csv: file_fixture("imports/ibkr_activity_statement.csv").read,
      filename: "ibkr_activity_statement.csv"
    ).extract

    assert_equal "ibkr", result.provider
    assert_equal "csv", result.file_type
    assert_equal 1, result.accounts.size

    account = result.accounts.first
    assert_equal "IBKR 00000017", account["name"]
    assert_equal "ibkr:00000017", account["source_id"]
    assert_equal "Investment", account["account_type"]
    assert_equal "brokerage", account["subtype"]
    assert_equal "USD", account["currency"]
    assert_equal "1014.00", account["closing_balance"]
    assert_equal "2026-04-30", account["balance_date"]

    assert_equal 1, account["trades"].size
    trade = account["trades"].first
    assert_equal "2026-04-02", trade["date"]
    assert_equal "AAPL", trade["ticker"]
    assert_equal "10.00", trade["qty"]
    assert_equal "1020.00", trade["price"]
    assert_equal "-1701.00", trade["amount"]
    assert_equal "Buy", trade["activity_label"]
    assert_equal "ibkr:00000017:trade:2026-04-02:AAPL:10.00:1020.00:-1701.00", trade["external_id"]

    assert_equal 2, account["transactions"].size
    assert_equal [ "AAPL Dividend", "ACH Deposit" ], account["transactions"].map { |txn| txn["name"] }
    assert_equal [ "12.34", "1013.00" ], account["transactions"].map { |txn| txn["amount"] }

    assert_equal 1, account["positions"].size
    position = account["positions"].first
    assert_equal "AAPL", position["ticker"]
    assert_equal "12.00", position["qty"]
    assert_equal "1007.00", position["market_value"]
  end
end
