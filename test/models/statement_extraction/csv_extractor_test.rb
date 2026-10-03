require "test_helper"

class StatementExtraction::CsvExtractorTest < ActiveSupport::TestCase
  test "bank and wallet formats keep every occurrence and account" do
    %w[dbs paylah uob].each do |provider|
      csv = "Date,Account Number,Description,Debit,Credit,Balance,Currency\n2026-04-01,1111,Example purchase,12,0,88,SGD\n2026-04-01,1111,Example purchase,12,0,76,SGD\n2026-04-02,2222,Example deposit,0,5,105,SGD\n"
      result = StatementExtraction::CsvExtractor.new(raw_csv: csv, filename: "#{provider}-example.csv").extract
      assert_equal provider, result.provider
      assert_equal 2, result.accounts.size
      assert_equal 2, result.accounts.first["transactions"].size
      assert_equal "12.00", result.accounts.first["transactions"].first["amount"]
      assert_equal "-5.00", result.accounts.last["transactions"].first["amount"]
    end
  end

  test "CPF buckets use the latest dated balance" do
    csv = "Month,Account,Contribution,Withdrawal,Closing Balance,Currency\n2026-05,Ordinary Account,5,0,105,SGD\n2026-04,Ordinary Account,5,0,100,SGD\n2026-05,Special Account,4,0,104,SGD\n2026-05,Medisave Account,3,0,103,SGD\n2026-05,Retirement Account,2,0,102,SGD\n"
    result = StatementExtraction::CsvExtractor.new(raw_csv: csv, filename: "cpf-example.csv").extract
    assert_equal 4, result.accounts.size
    ordinary = result.accounts.find { |account| account["subtype"] == "cpf_ordinary" }
    assert_equal "105.00", ordinary["closing_balance"]
    assert_equal "2026-05-31", ordinary["balance_date"]
    assert_equal "-5.00", ordinary["transactions"].first["amount"]
  end

  test "IBKR keeps trades cash activity balances and informational positions" do
    csv = "Section,Account ID,Date,Description,Symbol,Quantity,Price,Amount,Closing Balance,Net Liquidation Value,Currency\nTrades,U1111,2026-04-01,Example buy,FAKE,2,10,20,,,USD\nCash Transactions,U1111,2026-04-02,Example dividend,,,,2,,,USD\nPositions,U1111,2026-04-30,Example position,FAKE,2,10,20,,,USD\nBalances,U1111,2026-04-30,Example balance,,,,,80,100,USD\n"
    result = StatementExtraction::CsvExtractor.new(raw_csv: csv, filename: "ibkr-example.csv").extract
    account = result.accounts.sole
    assert_equal "ibkr", result.provider
    assert_equal 1, account["trades"].size
    assert_equal 1, account["transactions"].size
    assert_equal 1, account["positions"].size
    assert_equal "100.00", account["closing_balance"]
  end
end
