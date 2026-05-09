require "test_helper"

class StatementImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "publish creates reviewed account transactions balance reconciliation and profile" do
    statement_import = @family.imports.create!(
      type: "StatementImport",
      raw_file_str: file_fixture("imports/dbs_statement.csv").read,
      date_format: "%Y-%m-%d",
      extracted_data: StatementExtraction::CsvExtractor.new(
        raw_csv: file_fixture("imports/dbs_statement.csv").read,
        filename: "dbs_statement.csv"
      ).extract.to_h
    )

    account_payload = statement_import.extracted_accounts.first
    statement_import.update_review_account!(
      account_payload["source_id"],
      action: "create",
      account_id: nil,
      account_type: "Depository",
      account_subtype: "checking",
      account_name: "DBS Savings",
      currency: "SGD"
    )

    assert_difference -> { Account.count }, 1 do
      assert_difference -> { Transaction.count }, 3 do
        assert_difference -> { StatementProfile.count }, 1 do
          statement_import.publish
        end
      end
    end

    account = @family.accounts.find_by!(name: "DBS Savings")
    assert_equal "Depository", account.accountable_type
    assert_equal "SGD", account.currency
    assert_equal 3, statement_import.entries.where(entryable_type: "Transaction").count
    assert statement_import.entries.exists?(source: "statement_import", external_id: "dbs:5678:2026-04-01:12.50:PayNow Transfer")

    profile = @family.statement_profiles.find_by!(provider: "dbs", source_id: "dbs:5678")
    assert_equal account, profile.account
    assert_equal Date.parse("2026-04-03"), profile.last_statement_end_on
  end

  test "publish requires review decisions" do
    statement_import = @family.imports.create!(
      type: "StatementImport",
      raw_file_str: file_fixture("imports/dbs_statement.csv").read,
      date_format: "%Y-%m-%d",
      extracted_data: StatementExtraction::CsvExtractor.new(
        raw_csv: file_fixture("imports/dbs_statement.csv").read,
        filename: "dbs_statement.csv"
      ).extract.to_h
    )

    statement_import.publish

    assert_equal "failed", statement_import.reload.status
    assert_match "review", statement_import.error
  end

  test "publish creates IBKR brokerage trades cash transactions balance profile and skips duplicates" do
    Security::Resolver.any_instance.stubs(:resolve).returns(securities(:aapl))

    statement_import = @family.imports.create!(
      type: "StatementImport",
      raw_file_str: file_fixture("imports/ibkr_activity_statement.csv").read,
      date_format: "%Y-%m-%d",
      extracted_data: StatementExtraction::CsvExtractor.new(
        raw_csv: file_fixture("imports/ibkr_activity_statement.csv").read,
        filename: "ibkr_activity_statement.csv"
      ).extract.to_h
    )

    account_payload = statement_import.extracted_accounts.first
    statement_import.update_review_account!(
      account_payload["source_id"],
      action: "create",
      account_id: nil,
      account_type: "Investment",
      account_subtype: "brokerage",
      account_name: "IBKR Brokerage",
      currency: "USD"
    )

    assert_difference -> { Account.count }, 1 do
      assert_difference -> { Transaction.count }, 2 do
        assert_difference -> { Trade.count }, 1 do
          assert_difference -> { StatementProfile.count }, 1 do
            statement_import.publish
          end
        end
      end
    end

    account = @family.accounts.find_by!(name: "IBKR Brokerage")
    assert_equal "Investment", account.accountable_type
    assert_equal "brokerage", account.subtype
    assert_equal "USD", account.currency
    assert_equal 2, statement_import.entries.where(entryable_type: "Transaction").count
    assert_equal 1, statement_import.entries.where(entryable_type: "Trade").count
    assert statement_import.entries.exists?(source: "statement_import", external_id: "ibkr:4567:trade:2026-04-02:AAPL:10.00:170.00:-1701.00")
    assert statement_import.entries.exists?(source: "statement_import", external_id: "ibkr:4567:cash:2026-04-15:12.34:AAPL Dividend")

    trade = account.trades.first
    assert_equal securities(:aapl), trade.security
    assert_equal BigDecimal("10.00"), trade.qty
    assert_equal BigDecimal("170.00"), trade.price
    assert_equal "Buy", trade.investment_activity_label

    profile = @family.statement_profiles.find_by!(provider: "ibkr", source_id: "ibkr:4567")
    assert_equal account, profile.account
    assert_equal Date.parse("2026-04-30"), profile.last_statement_end_on
    assert_equal "1", profile.metadata.dig("counts", "positions").to_s

    assert_no_difference -> { Entry.count } do
      StatementExtraction::Publisher.new(statement_import).publish!
    end
  end
end
