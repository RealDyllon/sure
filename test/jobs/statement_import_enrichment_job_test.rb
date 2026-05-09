require "test_helper"

class StatementImportEnrichmentJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Statement enrichment", balance: 100, currency: "USD", accountable: Depository.new)
    @statement_import = @family.imports.create!(
      type: "StatementImport",
      raw_file_str: "Date,Description,Amount\n"
    )
  end

  test "runs merchant detection before categorization in batches" do
    transaction_ids = (1..45).to_a
    sequence = sequence("statement import enrichment")

    @family.expects(:auto_detect_transaction_merchants).with(transaction_ids[0, 20]).in_sequence(sequence)
    @family.expects(:auto_categorize_transactions).with(transaction_ids[0, 20]).in_sequence(sequence)
    @family.expects(:auto_detect_transaction_merchants).with(transaction_ids[20, 20]).in_sequence(sequence)
    @family.expects(:auto_categorize_transactions).with(transaction_ids[20, 20]).in_sequence(sequence)
    @family.expects(:auto_detect_transaction_merchants).with(transaction_ids[40, 5]).in_sequence(sequence)
    @family.expects(:auto_categorize_transactions).with(transaction_ids[40, 5]).in_sequence(sequence)

    StatementImportEnrichmentJob.perform_now(@statement_import, transaction_ids: transaction_ids)
  end

  test "does nothing with blank transaction ids" do
    @family.expects(:auto_detect_transaction_merchants).never
    @family.expects(:auto_categorize_transactions).never

    StatementImportEnrichmentJob.perform_now(@statement_import, transaction_ids: [])
    StatementImportEnrichmentJob.perform_now(@statement_import, transaction_ids: nil)
  end

  test "respects locked enrichable fields" do
    llm_provider = mock
    Provider::Registry.stubs(:default_llm_provider).returns(llm_provider)
    llm_provider.expects(:auto_detect_merchants).never
    llm_provider.expects(:auto_categorize).never

    transaction = create_transaction(account: @account, name: "Locked imported transaction").transaction
    transaction.lock_attr!(:merchant_id)
    transaction.lock_attr!(:category_id)

    assert_no_difference "DataEnrichment.count" do
      StatementImportEnrichmentJob.perform_now(@statement_import, transaction_ids: [ transaction.id ])
    end

    assert_nil transaction.reload.merchant
    assert_nil transaction.category
  end
end
