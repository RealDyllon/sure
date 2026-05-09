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
end
