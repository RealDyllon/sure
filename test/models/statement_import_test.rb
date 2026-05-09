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

  test "original filename preserves stored csv upload filename" do
    statement_import = @family.imports.create!(
      type: "StatementImport",
      raw_file_str: "Date,Description,Amount\n2026-04-01,Test,1.00",
      statement_original_filename: "uob_statement.csv"
    )

    assert_equal "uob_statement.csv", statement_import.original_filename
  end

  test "publish normalizes PDF transaction signs to Sure entry convention" do
    statement_import = @family.imports.create!(
      type: "StatementImport",
      date_format: "%Y-%m-%d",
      extracted_data: {
        "provider" => "dbs",
        "file_type" => "pdf",
        "statement_period" => { "end_date" => "2026-04-30" },
        "review_confirmed" => true,
        "accounts" => [
          {
            "source_id" => "dbs:1234",
            "name" => "DBS 1234",
            "account_type" => "Depository",
            "subtype" => "checking",
            "currency" => "SGD",
            "closing_balance" => "900.00",
            "balance_date" => "2026-04-30",
            "transactions" => [
              {
                "date" => "2026-04-01",
                "name" => "Coffee",
                "amount" => "-5.50",
                "currency" => "SGD",
                "external_id" => "dbs:1234:pdf:coffee"
              },
              {
                "date" => "2026-04-02",
                "name" => "Salary",
                "amount" => "1000.00",
                "currency" => "SGD",
                "external_id" => "dbs:1234:pdf:salary"
              }
            ],
            "review" => {
              "action" => "create",
              "account_type" => "Depository",
              "account_subtype" => "checking",
              "account_name" => "DBS PDF",
              "currency" => "SGD"
            }
          }
        ]
      }
    )

    statement_import.publish

    assert_equal "complete", statement_import.reload.status
    assert_equal BigDecimal("5.50"), statement_import.entries.find_by!(external_id: "dbs:1234:pdf:coffee").amount
    assert_equal BigDecimal("-1000.00"), statement_import.entries.find_by!(external_id: "dbs:1234:pdf:salary").amount
  end

  test "publish creates transactions profiles and balances for multiple DBS PDF accounts" do
    statement_import = @family.imports.create!(
      type: "StatementImport",
      date_format: "%Y-%m-%d",
      extracted_data: {
        "provider" => "dbs",
        "file_type" => "pdf",
        "statement_period" => { "end_date" => "2026-04-30" },
        "review_confirmed" => true,
        "accounts" => [
          {
            "source_id" => "dbs:1234",
            "name" => "DBS Multiplier Account",
            "account_type" => "Depository",
            "subtype" => "checking",
            "currency" => "SGD",
            "closing_balance" => "900.00",
            "balance_date" => "2026-04-30",
            "transactions" => [
              {
                "date" => "2026-04-10",
                "name" => "Coffee",
                "amount" => "-5.50",
                "currency" => "SGD",
                "external_id" => "dbs:1234:pdf:coffee"
              }
            ],
            "review" => {
              "action" => "create",
              "account_type" => "Depository",
              "account_subtype" => "checking",
              "account_name" => "DBS Current",
              "currency" => "SGD"
            }
          },
          {
            "source_id" => "dbs:5678",
            "name" => "DBS Savings Plus",
            "account_type" => "Depository",
            "subtype" => "savings",
            "currency" => "SGD",
            "closing_balance" => "2500.00",
            "balance_date" => "2026-04-30",
            "transactions" => [
              {
                "date" => "2026-04-15",
                "name" => "Interest",
                "amount" => "1.25",
                "currency" => "SGD",
                "external_id" => "dbs:5678:pdf:interest"
              }
            ],
            "review" => {
              "action" => "create",
              "account_type" => "Depository",
              "account_subtype" => "savings",
              "account_name" => "DBS Savings",
              "currency" => "SGD"
            }
          }
        ]
      }
    )

    assert_difference -> { Account.count }, 2 do
      assert_difference -> { Transaction.count }, 2 do
        assert_difference -> { StatementProfile.count }, 2 do
          statement_import.publish
        end
      end
    end

    current = @family.accounts.find_by!(name: "DBS Current")
    savings = @family.accounts.find_by!(name: "DBS Savings")

    assert_equal "checking", current.subtype
    assert_equal "savings", savings.subtype
    assert_equal BigDecimal("5.50"), current.entries.find_by!(external_id: "dbs:1234:pdf:coffee").amount
    assert_equal BigDecimal("-1.25"), savings.entries.find_by!(external_id: "dbs:5678:pdf:interest").amount
    assert_equal current, @family.statement_profiles.find_by!(provider: "dbs", source_id: "dbs:1234").account
    assert_equal savings, @family.statement_profiles.find_by!(provider: "dbs", source_id: "dbs:5678").account
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
