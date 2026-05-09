require "test_helper"

class StatementImportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in @user = users(:family_admin)
    ensure_tailwind_build
  end

  test "uploads csv statement as StatementImport" do
    assert_difference "StatementImport.count", 1 do
      post imports_url, params: {
        import: {
          type: "StatementImport",
          import_file: file_fixture_upload("imports/dbs_statement.csv", "text/csv")
        }
      }
    end

    created_import = StatementImport.order(:created_at).last
    assert_redirected_to import_url(created_import)
    assert_equal "csv", created_import.file_type
    assert_equal "dbs_statement.csv", created_import.statement_original_filename
  end

  test "uploads IBKR csv statement as StatementImport" do
    assert_difference "StatementImport.count", 1 do
      post imports_url, params: {
        import: {
          type: "StatementImport",
          import_file: file_fixture_upload("imports/ibkr_activity_statement.csv", "text/csv")
        }
      }
    end

    created_import = StatementImport.order(:created_at).last
    assert_redirected_to import_url(created_import)
    assert_equal "csv", created_import.file_type
  end

  test "routes dragged IBKR csv to StatementImport even from raw transaction form" do
    assert_difference "StatementImport.count", 1 do
      assert_no_difference "TransactionImport.count" do
        post imports_url, params: {
          import: {
            type: "TransactionImport",
            import_file: file_fixture_upload("imports/ibkr_activity_statement.csv", "text/csv")
          }
        }
      end
    end

    created_import = StatementImport.order(:created_at).last
    assert_redirected_to import_url(created_import)
  end

  test "uploads pdf statement as StatementImport and enqueues processing" do
    assert_enqueued_jobs 1, only: ProcessStatementImportJob do
      assert_difference "StatementImport.count", 1 do
        post imports_url, params: {
          import: {
            type: "StatementImport",
            statement_pdf_password: "secret-password",
            import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
          }
        }
      end
    end

    created_import = StatementImport.order(:created_at).last
    assert_redirected_to import_url(created_import)
    assert_equal "pdf", created_import.file_type
    assert_equal "sample_bank_statement.pdf", created_import.statement_original_filename
    assert_equal "secret-password", created_import.statement_pdf_password
    assert created_import.pdf_file.attached?
    assert_equal "sample_bank_statement.pdf", created_import.pdf_file.filename.to_s
  end

  test "rejects invalid pdf statement without orphaning import" do
    assert_no_enqueued_jobs only: ProcessStatementImportJob do
      assert_no_difference "StatementImport.count" do
        post imports_url, params: {
          import: {
            type: "StatementImport",
            import_file: file_fixture_upload("profile_image.png", "application/pdf")
          }
        }
      end
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.invalid_pdf"), flash[:alert]
  end

  test "saves statement review create and match account decisions" do
    matched_account = accounts(:depository)
    statement_import = statement_import_with_review_accounts(
      [
        {
          "source_id" => "dbs:5678",
          "name" => "DBS Multiplier",
          "account_type" => "Depository",
          "subtype" => "checking",
          "currency" => "SGD",
          "transactions" => []
        },
        {
          "source_id" => "uob:one",
          "name" => "UOB One",
          "account_type" => "Depository",
          "subtype" => "savings",
          "currency" => "SGD",
          "transactions" => []
        }
      ]
    )

    patch import_url(statement_import), params: {
      statement_import: {
        accounts: {
          "0" => {
            source_id: "dbs:5678",
            action: "match",
            account_id: matched_account.id,
            account_type: "Depository",
            account_subtype: "checking",
            account_name: matched_account.name,
            currency: "USD"
          },
          "1" => {
            source_id: "uob:one",
            action: "create",
            account_type: "Depository",
            account_subtype: "savings",
            account_name: "Example Reserve Account",
            currency: "SGD"
          }
        }
      }
    }

    assert_redirected_to import_url(statement_import)
    assert_equal I18n.t("imports.update.statement_review_saved", default: "Statement review saved."), flash[:notice]

    statement_import.reload
    assert_equal true, statement_import.extracted_data["review_confirmed"]

    matched_review = statement_import.extracted_accounts.find { |account| account["source_id"] == "dbs:5678" }["review"]
    assert_equal "match", matched_review["action"]
    assert_equal matched_account.id, matched_review["account_id"]
    assert_equal "Depository", matched_review["account_type"]
    assert_equal "checking", matched_review["account_subtype"]
    assert_equal matched_account.name, matched_review["account_name"]
    assert_equal "USD", matched_review["currency"]

    created_review = statement_import.extracted_accounts.find { |account| account["source_id"] == "uob:one" }["review"]
    assert_equal "create", created_review["action"]
    assert_nil created_review["account_id"]
    assert_equal "Depository", created_review["account_type"]
    assert_equal "savings", created_review["account_subtype"]
    assert_equal "Example Reserve Account", created_review["account_name"]
    assert_equal "SGD", created_review["currency"]
  end

  test "statement review match does not persist inaccessible account id" do
    other_family_account = families(:empty).accounts.create!(
      name: "Other Family Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    statement_import = statement_import_with_review_accounts(
      [
        {
          "source_id" => "dbs:9999",
          "name" => "DBS Other",
          "account_type" => "Depository",
          "subtype" => "checking",
          "currency" => "USD",
          "transactions" => []
        }
      ]
    )

    patch import_url(statement_import), params: {
      statement_import: {
        accounts: {
          "0" => {
            source_id: "dbs:9999",
            action: "match",
            account_id: other_family_account.id,
            account_type: "Depository",
            account_subtype: "checking",
            account_name: "DBS Other",
            currency: "USD"
          }
        }
      }
    }

    assert_redirected_to import_url(statement_import)

    review = statement_import.reload.extracted_accounts.first["review"]
    assert_equal "match", review["action"]
    assert_nil review["account_id"]
    assert_not statement_import.review_complete?
  end

  test "review page preselects matched manual account but still requires publish review" do
    account = accounts(:depository)
    account.update!(name: "DBS Multiplier 5678", currency: "SGD")

    statement_import = account.family.imports.create!(
      type: "StatementImport",
      raw_file_str: "already extracted",
      date_format: "%Y-%m-%d",
      extracted_data: {
        "provider" => "dbs",
        "file_type" => "pdf",
        "statement_period" => { "end_date" => "2026-04-30" },
        "accounts" => [
          {
            "source_id" => "dbs:5678",
            "name" => "Example Checking Account",
            "account_type" => "Depository",
            "subtype" => "checking",
            "currency" => "SGD",
            "transactions" => [],
            "review" => {
              "action" => "match",
              "account_id" => account.id,
              "account_type" => "Depository",
              "account_subtype" => "checking",
              "account_name" => account.name,
              "currency" => "SGD"
            }
          }
        ]
      }
    )

    assert_no_enqueued_jobs only: ProcessStatementImportJob do
      get import_url(statement_import)
    end

    assert_response :success
    assert_select "[data-controller='statement-review']", 1
    assert_select "[data-controller='statement-review-form'][data-statement-review-form-clean-value='false']", 1
    assert_select "form[data-action='input->statement-review-form#markDirty change->statement-review-form#markDirty']", 1
    assert_select "input[type='submit'][data-statement-review-form-target='saveButton'].bg-inverse", 1
    assert_select "select[name='statement_import[accounts][0][account_id]'] option[selected][value='#{account.id}']", text: account.name
    assert_select "[data-statement-review-target='existingAccountField'].invisible", 0
    assert_select "form[action='#{import_path(statement_import)}']"
    assert_select "form[action='#{publish_import_path(statement_import)}']", 0
    assert_select "[data-controller='page-polling']", 0
  end

  test "review page hides existing account selector when creating account" do
    statement_import = @user.family.imports.create!(
      type: "StatementImport",
      raw_file_str: "already extracted",
      date_format: "%Y-%m-%d",
      extracted_data: {
        "provider" => "uob",
        "file_type" => "pdf",
        "review_confirmed" => true,
        "accounts" => [
          {
            "source_id" => "uob:one",
            "name" => "Example Reserve Account",
            "account_type" => "Depository",
            "currency" => "SGD",
            "transactions" => [],
            "review" => {
              "action" => "create",
              "account_name" => "Example Reserve Account",
              "account_type" => "Depository",
              "currency" => "SGD"
            }
          }
        ]
      }
    )

    get import_url(statement_import)

    assert_response :success
    assert_select "[data-controller='statement-review']", 1
    assert_select "[data-controller='statement-review-form'][data-statement-review-form-clean-value='true']", 1
    assert_select "[data-statement-review-target='existingAccountField'].invisible[aria-hidden='true']", 1
    assert_select "select[name='statement_import[accounts][0][account_id]'][disabled]", 1
    assert_select "input[type='submit'][data-statement-review-form-target='saveButton'].bg-surface-inset", 1
    assert_select "button[type='submit'][data-statement-review-form-target='publishButton'].bg-inverse", 1
  end

  test "processing page polls the import status page" do
    statement_import = @user.family.imports.create!(
      type: "StatementImport",
      raw_file_str: "processing statement",
      status: :importing,
      date_format: "%Y-%m-%d"
    )

    get import_url(statement_import)

    assert_response :success
    assert_select "[data-controller='page-polling'][data-page-polling-url-value='#{import_path(statement_import)}'][data-page-polling-interval-value='3000']"
    assert_select "[role='progressbar'][aria-valuenow='0'][aria-valuemin='0'][aria-valuemax='100']", 1
    assert_select "p", text: I18n.t("imports.progress.default_message")
    assert_select "a[href='#{import_path(statement_import)}']", text: "Check status"
  end

  test "processing page renders progress and stale retry button" do
    statement_import = @user.family.imports.create!(
      type: "StatementImport",
      raw_file_str: "processing statement",
      status: :importing,
      date_format: "%Y-%m-%d"
    )

    StatementImport.any_instance.stubs(:processing_progress).returns({
      "message" => "Extracting transactions",
      "current" => 7,
      "total" => 10,
      "percent" => 70,
      "last_updated_at" => 10.minutes.ago.iso8601,
      "retry_count" => 0
    })
    StatementImport.any_instance.stubs(:processing_progress_percent).returns(70)
    StatementImport.any_instance.stubs(:processing_progress_stale?).returns(true)

    get import_url(statement_import)

    assert_response :success
    assert_select "[role='progressbar'][aria-valuenow='70'][aria-valuemin='0'][aria-valuemax='100']", 1
    assert_select "p", text: "Extracting transactions"
    assert_select "span", text: "7 / 10"
    assert_select "p", text: I18n.t("imports.progress.stale_message")
    assert_select "form[action='#{retry_processing_import_path(statement_import)}'][method='post'] button", text: I18n.t("imports.progress.retry_processing")
  end

  test "retry processing queues a statement import and resets progress" do
    statement_import = @user.family.imports.create!(
      type: "StatementImport",
      raw_file_str: "processing statement",
      status: :importing,
      error: "Timed out",
      date_format: "%Y-%m-%d",
      processing_progress: {
        "message" => "Extracting transactions",
        "current" => 4,
        "total" => 10,
        "percent" => 40,
        "last_updated_at" => 10.minutes.ago.iso8601,
        "retry_count" => 0
      }
    )

    assert_enqueued_with(job: ProcessStatementImportJob) do
      post retry_processing_import_url(statement_import)
    end

    assert_redirected_to import_url(statement_import)
    assert_equal I18n.t("imports.retry_processing.started"), flash[:notice]
    statement_import.reload
    assert_equal "pending", statement_import.status
    assert_nil statement_import.error
    assert_equal "queued", statement_import.processing_progress["phase"]
    assert_equal I18n.t("imports.progress.retry_queued"), statement_import.processing_progress["message"]
    assert_equal 0, statement_import.processing_progress["current"]
    assert_equal 10, statement_import.processing_progress["total"]
    assert_equal 1, statement_import.processing_progress["retry_count"]
    assert statement_import.processing_progress["job_id"].present?
  end

  test "retry processing rejects active non-stale imports" do
    statement_import = @user.family.imports.create!(
      type: "StatementImport",
      raw_file_str: "processing statement",
      status: :importing,
      date_format: "%Y-%m-%d",
      processing_progress: {
        "message" => "Extracting transactions",
        "current" => 4,
        "total" => 10,
        "percent" => 40,
        "last_updated_at" => Time.current.iso8601,
        "retry_count" => 0
      }
    )

    assert_no_enqueued_jobs only: ProcessStatementImportJob do
      post retry_processing_import_url(statement_import)
    end

    assert_redirected_to import_url(statement_import)
    assert_equal I18n.t("imports.retry_processing.not_retryable"), flash[:alert]
    assert_equal "importing", statement_import.reload.status
  end

  test "retry processing rejects imports at retry limit" do
    statement_import = @user.family.imports.create!(
      type: "StatementImport",
      raw_file_str: "processing statement",
      status: :importing,
      date_format: "%Y-%m-%d",
      processing_progress: {
        "message" => "Extracting transactions",
        "current" => 4,
        "total" => 10,
        "percent" => 40,
        "last_updated_at" => 10.minutes.ago.iso8601,
        "retry_count" => StatementImport::MAX_PROCESSING_RETRIES
      }
    )

    assert_no_enqueued_jobs only: ProcessStatementImportJob do
      post retry_processing_import_url(statement_import)
    end

    assert_redirected_to import_url(statement_import)
    assert_equal I18n.t("imports.retry_processing.not_retryable"), flash[:alert]
  end

  test "pdf password retry replaces stale processing job ownership" do
    statement_import = @user.family.imports.create!(
      type: "StatementImport",
      status: :failed,
      error: "Incorrect password",
      date_format: "%Y-%m-%d",
      processing_progress: {
        "job_id" => "old-job",
        "phase" => "failed",
        "message" => "Incorrect password",
        "retry_count" => 0
      }
    )
    statement_import.pdf_file.attach(
      io: file_fixture("imports/sample_bank_statement.pdf").open,
      filename: "sample_bank_statement.pdf",
      content_type: "application/pdf"
    )

    assert_enqueued_with(job: ProcessStatementImportJob) do
      patch import_url(statement_import), params: {
        statement_import: {
          statement_pdf_password: "secret"
        }
      }
    end

    assert_redirected_to import_url(statement_import)
    progress = statement_import.reload.processing_progress
    assert_equal "pending", statement_import.status
    assert_nil statement_import.error
    assert_equal "queued", progress["phase"]
    assert_not_equal "old-job", progress["job_id"]
    assert progress["job_id"].present?
  end

  private
    def statement_import_with_review_accounts(accounts)
      @user.family.imports.create!(
        type: "StatementImport",
        raw_file_str: "already extracted",
        status: :pending,
        date_format: "%Y-%m-%d",
        extracted_data: {
          "provider" => "dbs",
          "file_type" => "pdf",
          "statement_period" => { "end_date" => "2026-04-30" },
          "accounts" => accounts
        }
      )
    end
end
