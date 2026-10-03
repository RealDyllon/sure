require "test_helper"

class StatementImportTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @import = build_import
  end

  test "review is mandatory even when extraction proposes a match" do
    assert_not @import.publishable?
    confirm_match
    assert @import.publishable?
  end

  test "publishing retains identical occurrences and is idempotent" do
    confirm_match
    @import.publish
    assert @import.reload.complete?, @import.error
    assert_equal 2, @import.entries.transactions.count
    assert_equal 2, @import.entries.transactions.distinct.count(:external_id)
    @import.publish
    assert_equal 2, @import.entries.transactions.count
  end

  test "a failed later account rolls back the entire publication" do
    confirm_match
    bad = @import.extracted_accounts.first.deep_dup
    bad["source_id"] = "dbs:2222"
    bad["transactions"] = [ { "date" => "invalid", "amount" => "2", "name" => "Example purchase", "currency" => "USD" } ]
    @import.update!(extracted_data: @import.extracted_data.merge("accounts" => @import.extracted_accounts + [ bad ]))
    @import.publish
    assert @import.reload.failed?
    assert_empty @import.entries
    assert_empty @import.statement_import_accounts.reload
  end

  test "existing provider entries are reconciled once without overwriting edits" do
    existing = @account.entries.create!(entryable: Transaction.new, amount: 12, currency: "USD", date: "2026-04-01", name: "Example edited purchase", source: "plaid", notes: "Example note")
    confirm_match
    @import.publish
    assert @import.reload.complete?, @import.error
    assert_equal 1, @import.entries.transactions.count
    assert_equal @import.account_statement_id, existing.reload.reconciled_by_statement_id
    assert_equal "Example edited purchase", existing.name
    assert_equal "Example note", existing.notes
    @import.revert
    assert @import.reload.pending?, @import.error
    assert_nil existing.reload.reconciled_by_statement_id
    assert_equal "Example note", existing.notes
  end

  test "closing balances restore prior valuations on reversal" do
    valuation = @account.entries.create!(entryable: Valuation.new(kind: "reconciliation"), amount: 100, currency: "USD", date: "2026-04-30", name: "Example balance")
    payload = @import.extracted_accounts.first.merge("closing_balance" => "76", "balance_date" => "2026-04-30")
    @import.update!(extracted_data: @import.extracted_data.merge("accounts" => [ payload ]))
    confirm_match
    @import.publish
    assert @import.reload.complete?, @import.error
    assert_equal 76, valuation.reload.amount
    @import.revert
    assert @import.reload.pending?, @import.error
    assert_equal 100, valuation.reload.amount
  end

  test "reversal preserves a valuation changed after publication" do
    valuation = @account.entries.create!(entryable: Valuation.new(kind: "reconciliation"), amount: 100, currency: "USD", date: "2026-04-30", name: "Example balance")
    payload = @import.extracted_accounts.first.merge("closing_balance" => "76", "balance_date" => "2026-04-30")
    @import.update!(extracted_data: @import.extracted_data.merge("accounts" => [ payload ]))
    confirm_match
    @import.publish
    valuation.reload.update!(amount: 90)
    @import.revert
    assert @import.reload.revert_failed?
    assert_equal 90, valuation.reload.amount
    assert_equal 2, @import.entries.transactions.count
  end

  test "investment trades retain repeated occurrences and reverse safely" do
    account = accounts(:investment)
    security = securities(:aapl)
    Security::Resolver.any_instance.stubs(:resolve).returns(security)
    trade = { "date" => "2026-04-01", "ticker" => "EXAMPLE", "qty" => "2", "price" => "6", "amount" => "12", "currency" => account.currency, "name" => "Example trade" }
    payload = @import.extracted_accounts.first.merge("currency" => account.currency, "transactions" => [], "trades" => [ trade, trade.dup ])
    @import.update!(extracted_data: @import.extracted_data.merge("accounts" => [ payload ]))
    @import.save_review!("dbs:1111" => { "action" => "match", "account_id" => account.id })
    @import.publish
    assert @import.reload.complete?, @import.error
    assert_equal 2, @import.entries.trades.count
    assert_equal 2, @import.entries.trades.distinct.count(:external_id)
    @import.revert
    assert @import.reload.pending?, @import.error
    assert_empty @import.entries
    assert Account.exists?(account.id)
  end

  test "access is checked again at publish time" do
    confirm_match
    @account.update!(owner: users(:family_member))
    @account.account_shares.destroy_all
    @import.publish
    assert @import.reload.failed?
    assert_empty @import.entries
  end

  test "create and revert removes only accounts and entries created by this import" do
    review = { "action" => "create", "account_name" => "Example Checking Account", "account_type" => "Depository", "account_subtype" => "checking", "currency" => "USD" }
    @import.save_review!("dbs:1111" => review)
    @import.publish
    assert @import.reload.complete?, @import.error
    id = @import.accounts.sole.id
    assert_equal 2, @import.entries.transactions.count
    @import.revert
    assert @import.reload.pending?, @import.error
    assert_not Account.exists?(id)
  end

  test "revert refuses to delete a new account with later independent activity" do
    @import.save_review!("dbs:1111" => { "action" => "create", "account_name" => "Example Checking Account", "account_type" => "Depository", "currency" => "USD" })
    @import.publish
    account = @import.accounts.sole
    account.entries.create!(entryable: Transaction.new, amount: 1, currency: "USD", date: "2026-04-02", name: "Example later purchase")
    @import.revert
    assert @import.reload.revert_failed?
    assert Account.exists?(account.id)
    assert_equal 2, @import.entries.transactions.count
  end

  test "vault file is private to the initiating user" do
    assert @import.account_statement.viewable_by?(@user)
    assert_not @import.account_statement.viewable_by?(users(:family_member))
    assert_not AccountStatement.visible_to(users(:family_member)).exists?(@import.account_statement.id)
  end

  test "an old extraction job cannot overwrite a newer attempt" do
    @import.update!(status: :importing, processing_progress: { "job_id" => "new-job" })
    assert_not @import.update_processing_progress!(job_id: "old-job", phase: "failed")
    assert_equal "new-job", @import.reload.processing_progress["job_id"]
  end

  private
    def build_import
      file = Tempfile.new([ "dbs-example", ".csv" ])
      file.write("Date,Description,Amount,Currency,Account Number\n2026-04-01,Example purchase,12,USD,1111\n")
      file.rewind
      upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "dbs-example.csv", type: "text/csv")
      statement = AccountStatement.create_from_upload!(family: @user.family, account: nil, file: upload)
      row = { "date" => "2026-04-01", "name" => "Example purchase", "amount" => "12", "currency" => "USD" }
      StatementImport.create!(family: @user.family, account_statement: statement, initiating_user: @user, extracted_data: { "provider" => "dbs", "file_type" => "csv", "accounts" => [ { "source_id" => "dbs:1111", "name" => "Example Checking Account", "currency" => "USD", "transactions" => [ row, row.dup ] } ] })
    ensure
      file&.close!
    end

    def confirm_match
      @import.save_review!("dbs:1111" => { "action" => "match", "account_id" => @account.id })
    end
end
