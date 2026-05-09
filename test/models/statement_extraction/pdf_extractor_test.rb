require "test_helper"

class StatementExtraction::PdfExtractorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "normalizes IBKR PDF extraction as brokerage account with trades and positions" do
    provider = mock("openai_provider")
    provider.expects(:extract_bank_statement).returns(
      Provider::Response.new(
        success?: true,
        data: {
          bank_name: "Interactive Brokers",
          account_id: "U1234567",
          base_currency: "USD",
          period: { end_date: "2026-04-30" },
          net_liquidation_value: "7100.00",
          cash_balance: "5000.00",
          cash_transactions: [
            { date: "2026-04-15", description: "AAPL Dividend", amount: "12.34", currency: "USD" }
          ],
          trades: [
            { date: "2026-04-02", symbol: "AAPL", quantity: "10.00", price: "170.00", amount: "-1701.00", currency: "USD" }
          ],
          positions: [
            { date: "2026-04-30", symbol: "AAPL", quantity: "12.00", price: "173.00", market_value: "2076.00", currency: "USD" }
          ]
        },
        error: nil
      )
    )
    Provider::Registry.stubs(:get_provider).with(:openai).returns(provider)

    statement_import = StatementImport.new(family: @family)
    statement_import.stubs(:pdf_file_content).returns("pdf")

    result = StatementExtraction::PdfExtractor.new(statement_import).extract

    assert_equal "ibkr", result.provider
    account = result.accounts.first
    assert_equal "ibkr:4567", account["source_id"]
    assert_equal "Investment", account["account_type"]
    assert_equal "brokerage", account["subtype"]
    assert_equal "7100.00", account["closing_balance"]
    assert_equal "5000.00", account["cash_balance"]
    assert_equal 1, account["transactions"].size
    assert_equal 1, account["trades"].size
    assert_equal 1, account["positions"].size
  end
end
