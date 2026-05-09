require "test_helper"

class RecoverStalledStatementImportsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "queues one retry for stale statement imports" do
    statement_import = @family.imports.create!(
      type: "StatementImport",
      raw_file_str: "Date,Description,Amount\n2026-04-01,Test,1.00",
      status: :importing,
      processing_progress: {
        "phase" => "extracting",
        "message" => "Processing chunk 1 of 3",
        "current" => 1,
        "total" => 3,
        "last_updated_at" => (Import::PROCESSING_PROGRESS_STALE_AFTER + 1.minute).ago.iso8601,
        "retry_count" => 0
      }
    )

    assert_enqueued_jobs 1, only: ProcessStatementImportJob do
      RecoverStalledStatementImportsJob.perform_now
    end

    progress = statement_import.reload.processing_progress
    assert_equal "pending", statement_import.status
    assert_equal "queued", progress["phase"]
    assert_equal "Processing appeared stalled, so we queued one retry.", progress["message"]
    assert_equal 0, progress["current"]
    assert_equal 3, progress["total"]
    assert_equal 1, progress["retry_count"]
    assert_not_nil progress["job_id"]
  end

  test "does not queue retry for active or retry-limited statement imports" do
    @family.imports.create!(
      type: "StatementImport",
      raw_file_str: "Date,Description,Amount\n2026-04-01,Test,1.00",
      status: :importing,
      processing_progress: {
        "last_updated_at" => Time.current.iso8601,
        "retry_count" => 0
      }
    )
    @family.imports.create!(
      type: "StatementImport",
      raw_file_str: "Date,Description,Amount\n2026-04-01,Test,1.00",
      status: :importing,
      processing_progress: {
        "last_updated_at" => (Import::PROCESSING_PROGRESS_STALE_AFTER + 1.minute).ago.iso8601,
        "retry_count" => StatementImport::MAX_PROCESSING_RETRIES
      }
    )

    assert_no_enqueued_jobs only: ProcessStatementImportJob do
      RecoverStalledStatementImportsJob.perform_now
    end
  end
end
