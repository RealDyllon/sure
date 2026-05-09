require "test_helper"

class ProcessStatementImportJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "skips non-StatementImport imports" do
    pdf_import = imports(:pdf)

    ProcessStatementImportJob.perform_now(pdf_import)

    assert_equal "pending", pdf_import.reload.status
  end

  test "skips if statement import is not uploaded" do
    statement_import = create_statement_import

    statement_import.expects(:process_statement!).never

    ProcessStatementImportJob.perform_now(statement_import)

    assert_equal "pending", statement_import.reload.status
  end

  test "skips complete statement imports" do
    statement_import = create_statement_import(status: :complete, raw_file_str: statement_csv)

    statement_import.expects(:process_statement!).never

    ProcessStatementImportJob.perform_now(statement_import)

    assert_equal "complete", statement_import.reload.status
  end

  test "transitions to pending after processing and clears password" do
    statement_import = create_statement_import(
      raw_file_str: statement_csv,
      statement_pdf_password: "secret"
    )

    statement_import.expects(:process_statement!).once do
      assert_equal "importing", statement_import.reload.status
    end

    ProcessStatementImportJob.perform_now(statement_import)

    statement_import.reload
    assert_equal "pending", statement_import.status
    assert_nil statement_import.statement_pdf_password
  end

  test "marks failed with truncated error, clears password, and re-raises" do
    statement_import = create_statement_import(
      raw_file_str: statement_csv,
      statement_pdf_password: "secret"
    )
    error_message = "Processing failed: #{"x" * 600}"

    statement_import.expects(:process_statement!).once.raises(StandardError, error_message)

    error = assert_raises(StandardError) do
      ProcessStatementImportJob.perform_now(statement_import)
    end

    assert_equal error_message, error.message

    statement_import.reload
    assert_equal "failed", statement_import.status
    assert_equal error_message.truncate(500), statement_import.error
    assert_nil statement_import.statement_pdf_password
  end

  private

    def create_statement_import(attributes = {})
      @family.imports.create!(
        {
          type: "StatementImport",
          status: :pending
        }.merge(attributes)
      )
    end

    def statement_csv
      "date,description,amount\n2026-04-01,Coffee,-5.50\n"
    end
end
