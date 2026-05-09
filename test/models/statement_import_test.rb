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
end
