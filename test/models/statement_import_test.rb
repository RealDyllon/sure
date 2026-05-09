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

    enqueued_transaction_ids = nil
    StatementImportEnrichmentJob.expects(:perform_later).with do |import, transaction_ids:|
      enqueued_transaction_ids = transaction_ids
      import == statement_import && transaction_ids.size == 3
    end.once

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
    assert statement_import.entries.exists?(source: "statement_import", external_id: "dbs:00000018:2026-04-01:12.50:PayNow Transfer")
    assert_equal statement_import.entries.where(entryable_type: "Transaction").pluck(:entryable_id).sort, enqueued_transaction_ids.sort

    profile = @family.statement_profiles.find_by!(provider: "dbs", source_id: "dbs:00000018")
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
            "source_id" => "dbs:00000009",
            "name" => "DBS 00000009",
            "account_type" => "Depository",
            "subtype" => "checking",
            "currency" => "SGD",
            "closing_balance" => "1027.00",
            "balance_date" => "2026-04-30",
            "transactions" => [
              {
                "date" => "2026-04-01",
                "name" => "Coffee",
                "amount" => "-5.50",
                "currency" => "SGD",
                "external_id" => "dbs:00000009:pdf:coffee"
              },
              {
                "date" => "2026-04-02",
                "name" => "Salary",
                "amount" => "1002.00",
                "currency" => "SGD",
                "external_id" => "dbs:00000009:pdf:salary"
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
    assert_equal BigDecimal("5.50"), statement_import.entries.find_by!(external_id: "dbs:00000009:pdf:coffee").amount
    assert_equal BigDecimal("-1002.00"), statement_import.entries.find_by!(external_id: "dbs:00000009:pdf:salary").amount
  end

  test "publish does not enqueue enrichment when no new transactions are created" do
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
            "source_id" => "dbs:balance-only",
            "name" => "DBS Balance Only",
            "account_type" => "Depository",
            "subtype" => "checking",
            "currency" => "SGD",
            "closing_balance" => "1027.00",
            "balance_date" => "2026-04-30",
            "transactions" => [],
            "trades" => [],
            "review" => {
              "action" => "create",
              "account_type" => "Depository",
              "account_subtype" => "checking",
              "account_name" => "DBS Balance Only",
              "currency" => "SGD"
            }
          }
        ]
      }
    )

    StatementImportEnrichmentJob.expects(:perform_later).never

    assert_no_difference -> { Transaction.count } do
      statement_import.publish
    end

    assert_equal "complete", statement_import.reload.status
  end

  test "publish imports reviewed match into existing account without creating account" do
    account = accounts(:depository)
    account.update!(name: "Fixture Account 3", currency: "SGD")

    statement_import = build_reviewed_statement_import(
      source_id: "dbs:matched",
      account_name: "Fixture Account 3",
      closing_balance: "1004.00",
      transactions: [
        {
          "date" => "2026-04-12",
          "name" => "Matched Account Coffee",
          "amount" => "-6.25",
          "currency" => "SGD",
          "external_id" => "dbs:matched:coffee"
        }
      ],
      review: {
        "action" => "match",
        "account_id" => account.id,
        "account_type" => "Depository",
        "account_subtype" => "checking",
        "account_name" => account.name,
        "currency" => "SGD"
      }
    )

    enqueued_transaction_ids = nil
    StatementImportEnrichmentJob.expects(:perform_later).with do |import, transaction_ids:|
      enqueued_transaction_ids = transaction_ids
      import == statement_import && transaction_ids.size == 1
    end.once

    assert_no_difference -> { Account.count } do
      assert_difference -> { Transaction.count }, 1 do
        assert_difference -> { StatementProfile.count }, 1 do
          statement_import.publish
        end
      end
    end

    entry = account.entries.find_by!(source: "statement_import", external_id: "dbs:matched:coffee")
    assert_equal statement_import, entry.import
    assert_equal BigDecimal("6.25"), entry.amount
    assert_equal [ entry.entryable_id ], enqueued_transaction_ids
    assert_equal BigDecimal("1004.00"), account.reload.balance
    assert_equal account, @family.statement_profiles.find_by!(provider: "dbs", source_id: "dbs:matched").account
  end

  test "publish reuses current import statement profile account for create review" do
    account = accounts(:depository)
    account.update!(name: "Reusable DBS Account", currency: "SGD")

    statement_import = build_reviewed_statement_import(
      source_id: "dbs:reuse",
      account_name: "DBS Reuse",
      closing_balance: "1024.00",
      transactions: [
        {
          "date" => "2026-04-13",
          "name" => "Reusable Account Interest",
          "amount" => "0.25",
          "currency" => "SGD",
          "external_id" => "dbs:reuse:interest"
        }
      ],
      review: {
        "action" => "create",
        "account_id" => nil,
        "account_type" => "Depository",
        "account_subtype" => "checking",
        "account_name" => "New DBS Account",
        "currency" => "SGD"
      }
    )

    @family.statement_profiles.create!(
      account: account,
      provider: "dbs",
      source_id: "dbs:reuse",
      source_name: "DBS Reuse",
      account_type: "Depository",
      account_subtype: "checking",
      currency: "SGD",
      metadata: { "last_import_id" => statement_import.id }
    )

    StatementImportEnrichmentJob.expects(:perform_later).once

    assert_no_difference -> { Account.count } do
      assert_difference -> { Transaction.count }, 1 do
        statement_import.publish
      end
    end

    assert_nil @family.accounts.find_by(name: "New DBS Account")
    assert account.entries.exists?(source: "statement_import", external_id: "dbs:reuse:interest")

    profile = @family.statement_profiles.find_by!(provider: "dbs", source_id: "dbs:reuse")
    assert_equal account, profile.account
    assert_equal statement_import.id, profile.metadata["last_import_id"]
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
            "source_id" => "dbs:00000009",
            "name" => "Fixture Account 3",
            "account_type" => "Depository",
            "subtype" => "checking",
            "currency" => "SGD",
            "closing_balance" => "1027.00",
            "balance_date" => "2026-04-30",
            "transactions" => [
              {
                "date" => "2026-04-10",
                "name" => "Coffee",
                "amount" => "-5.50",
                "currency" => "SGD",
                "external_id" => "dbs:00000009:pdf:coffee"
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
            "source_id" => "dbs:00000018",
            "name" => "DBS Savings Plus",
            "account_type" => "Depository",
            "subtype" => "savings",
            "currency" => "SGD",
            "closing_balance" => "1010.00",
            "balance_date" => "2026-04-30",
            "transactions" => [
              {
                "date" => "2026-04-15",
                "name" => "Interest",
                "amount" => "1.25",
                "currency" => "SGD",
                "external_id" => "dbs:00000018:pdf:interest"
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
    assert_equal BigDecimal("5.50"), current.entries.find_by!(external_id: "dbs:00000009:pdf:coffee").amount
    assert_equal BigDecimal("-1.25"), savings.entries.find_by!(external_id: "dbs:00000018:pdf:interest").amount
    assert_equal current, @family.statement_profiles.find_by!(provider: "dbs", source_id: "dbs:00000009").account
    assert_equal savings, @family.statement_profiles.find_by!(provider: "dbs", source_id: "dbs:00000018").account
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
    assert statement_import.entries.exists?(source: "statement_import", external_id: "ibkr:00000017:trade:2026-04-02:AAPL:10.00:1020.00:-1701.00")
    assert statement_import.entries.exists?(source: "statement_import", external_id: "ibkr:00000017:cash:2026-04-15:12.34:AAPL Dividend")

    trade = account.trades.first
    assert_equal securities(:aapl), trade.security
    assert_equal BigDecimal("10.00"), trade.qty
    assert_equal BigDecimal("1020.00"), trade.price
    assert_equal "Buy", trade.investment_activity_label

    profile = @family.statement_profiles.find_by!(provider: "ibkr", source_id: "ibkr:00000017")
    assert_equal account, profile.account
    assert_equal Date.parse("2026-04-30"), profile.last_statement_end_on
    assert_equal "1", profile.metadata.dig("counts", "positions").to_s

    StatementImportEnrichmentJob.expects(:perform_later).never

    assert_no_difference -> { Entry.count } do
      StatementExtraction::Publisher.new(statement_import).publish!
    end
  end

  private

    def build_reviewed_statement_import(source_id:, account_name:, closing_balance:, transactions:, review:)
      @family.imports.create!(
        type: "StatementImport",
        date_format: "%Y-%m-%d",
        extracted_data: {
          "provider" => "dbs",
          "file_type" => "pdf",
          "statement_period" => { "end_date" => "2026-04-30" },
          "review_confirmed" => true,
          "accounts" => [
            {
              "source_id" => source_id,
              "name" => account_name,
              "account_type" => "Depository",
              "subtype" => "checking",
              "currency" => "SGD",
              "closing_balance" => closing_balance,
              "cash_balance" => closing_balance,
              "balance_date" => "2026-04-30",
              "transactions" => transactions,
              "review" => review
            }
          ]
        }
      )
    end
end
