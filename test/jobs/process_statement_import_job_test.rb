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

  test "sets progress through successful statement processing lifecycle" do
    statement_import = create_statement_import(raw_file_str: statement_csv, statement_pdf_password: "secret")

    StatementExtraction::Extractor.any_instance.expects(:extract).with do |progress_callback:|
      progress_callback.call(phase: :extracting, message: "Processing chunk 1 of 2", current: 1, total: 2)
      true
    end.returns(StatementExtraction::CsvExtractor.new(raw_csv: statement_import.raw_file_str, filename: "statement.csv").extract)

    ProcessStatementImportJob.perform_now(statement_import)

    progress = statement_import.reload.processing_progress
    assert_equal "pending", statement_import.status
    assert_nil statement_import.statement_pdf_password
    assert_equal "complete", progress["phase"]
    assert_equal "Ready for review", progress["message"]
    assert_equal 2, progress["current"]
    assert_equal 2, progress["total"]
    assert_equal 100, progress["percent"]
    assert_not_nil progress["job_id"]
    assert_not_nil progress["started_at"]
    assert_not_nil progress["last_updated_at"]
    assert_not_nil progress["finished_at"]
  end

  test "does not allow sidekiq to retry outside statement retry cap" do
    assert_equal false, ProcessStatementImportJob.get_sidekiq_options["retry"]
  end

  test "marks progress failed when statement processing raises" do
    statement_import = create_statement_import(raw_file_str: statement_csv, statement_pdf_password: "secret")

    StatementExtraction::Extractor.any_instance.expects(:extract).raises(StandardError, "provider timed out")

    assert_raises(StandardError) do
      ProcessStatementImportJob.perform_now(statement_import)
    end

    progress = statement_import.reload.processing_progress
    assert_equal "failed", statement_import.status
    assert_equal "provider timed out", statement_import.error
    assert_nil statement_import.statement_pdf_password
    assert_equal "failed", progress["phase"]
    assert_equal "provider timed out", progress["message"]
    assert_not_nil progress["finished_at"]
  end

  test "marks failed with truncated error, clears password, and re-raises" do
    statement_import = create_statement_import(raw_file_str: statement_csv, statement_pdf_password: "secret")
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

  test "stale job failure does not overwrite a newer retry" do
    statement_import = create_statement_import(
      raw_file_str: statement_csv,
      status: :importing,
      processing_progress: {
        "job_id" => "newer-job",
        "phase" => "extracting",
        "message" => "Processing newer retry",
        "retry_count" => 1
      }
    )

    statement_import.fail_processing_progress!(message: "old job failed", guard_job_id: "old-job")

    statement_import.reload
    assert_equal "importing", statement_import.status
    assert_nil statement_import.error
    assert_equal "newer-job", statement_import.processing_progress["job_id"]
    assert_equal "Processing newer retry", statement_import.processing_progress["message"]
  end

  test "stale queued job exits when a newer retry owns progress" do
    statement_import = create_statement_import(
      raw_file_str: statement_csv,
      status: :pending,
      processing_progress: {
        "job_id" => "newer-job",
        "phase" => "queued",
        "message" => "Processing retry queued",
        "retry_count" => 1
      }
    )

    StatementExtraction::Extractor.any_instance.expects(:extract).never

    ProcessStatementImportJob.perform_now(statement_import)

    statement_import.reload
    assert_equal "pending", statement_import.status
    assert_equal "newer-job", statement_import.processing_progress["job_id"]
    assert_equal "Processing retry queued", statement_import.processing_progress["message"]
  end

  test "running job does not persist extraction after newer retry takes ownership" do
    statement_import = create_statement_import(raw_file_str: statement_csv)

    result = StatementExtraction::CsvExtractor.new(raw_csv: statement_import.raw_file_str, filename: "statement.csv").extract
    StatementExtraction::Extractor.any_instance.expects(:extract).with do |progress_callback:|
      progress_callback.call(phase: :extracting, message: "Processing chunk 1 of 1", current: 1, total: 1)
      statement_import.reload.update!(
        processing_progress: statement_import.processing_progress.merge(
          "job_id" => "newer-job",
          "phase" => "queued",
          "message" => "Processing retry queued"
        )
      )
      true
    end.returns(result)

    ProcessStatementImportJob.perform_now(statement_import)

    statement_import.reload
    assert_nil statement_import.extracted_data
    assert_equal "importing", statement_import.status
    assert_equal "newer-job", statement_import.processing_progress["job_id"]
    assert_equal "Processing retry queued", statement_import.processing_progress["message"]
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
