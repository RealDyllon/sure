require "test_helper"

class StatementExtraction::PdfExtractorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "normalizes IBKR PDF extraction as brokerage account with trades and positions" do
    provider = mock("default_llm_provider")
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
    Provider::Registry.expects(:get_provider).never
    Provider::Registry.stubs(:default_llm_provider).returns(provider)

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

  test "normalizes DBS consolidated PDF extraction as separate statement accounts" do
    provider = mock("default_llm_provider")
    provider.expects(:extract_bank_statement).returns(
      Provider::Response.new(
        success?: true,
        data: {
          bank_name: "DBS Bank",
          period: { start_date: "2026-04-01", end_date: "2026-04-30" },
          accounts: [
            {
              account_name: "DBS Multiplier Account",
              account_number: "120-852720-3",
              account_type: "Depository",
              subtype: "checking",
              currency: "SGD",
              closing_balance: "900.00",
              transactions: [
                { date: "2026-04-10", name: "Coffee", amount: "-5.50", currency: "SGD" }
              ]
            },
            {
              account_name: "DBS Savings Plus",
              account_number: "5678",
              account_type: "Depository",
              subtype: "savings",
              currency: "SGD",
              closing_balance: "2500.00",
              transactions: [
                { date: "2026-04-15", name: "Interest", amount: "1.25", currency: "SGD" }
              ]
            }
          ]
        },
        error: nil
      )
    )
    Provider::Registry.expects(:get_provider).never
    Provider::Registry.stubs(:default_llm_provider).returns(provider)

    statement_import = StatementImport.new(family: @family, statement_original_filename: "dbs-apr.pdf")
    statement_import.stubs(:pdf_file_content).returns("pdf")

    result = StatementExtraction::PdfExtractor.new(statement_import).extract

    assert_equal "dbs", result.provider
    assert_equal "pdf", result.file_type
    assert_equal 2, result.accounts.size

    current = result.accounts.first
    savings = result.accounts.second

    assert_equal "dbs:7203", current["source_id"]
    assert_equal "DBS Multiplier Account", current["name"]
    assert_equal "checking", current["subtype"]
    assert_equal "900.00", current["closing_balance"]
    assert_equal "dbs:7203:2026-04-10:-5.50:Coffee", current["transactions"].first["external_id"]

    assert_equal "dbs:5678", savings["source_id"]
    assert_equal "DBS Savings Plus", savings["name"]
    assert_equal "savings", savings["subtype"]
    assert_equal "2500.00", savings["closing_balance"]
    assert_equal "dbs:5678:2026-04-15:1.25:Interest", savings["transactions"].first["external_id"]
  end
end
