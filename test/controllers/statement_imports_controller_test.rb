require "test_helper"

class StatementImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    ensure_tailwind_build
  end

  test "synthetic CSV uploads stay in the vault and extract asynchronously" do
    file = Tempfile.new([ "dbs-example", ".csv" ])
    file.write("Date,Account Number,Description,Debit,Credit,Balance,Currency\n2026-04-01,1111,Example purchase,12,0,88,USD\n")
    file.close
    upload = Rack::Test::UploadedFile.new(file.path, "text/csv", original_filename: "dbs-example.csv")
    assert_difference "StatementImport.count", 1 do
      post statement_imports_url, params: { statement_import: { file: upload } }
    end
    import = StatementImport.order(:created_at).last
    assert_redirected_to statement_import_url(import)
    get statement_import_url(import)
    assert_response :success
    job_id = import.processing_progress["job_id"]
    job = ProcessStatementImportJob.new(import)
    job.job_id = job_id
    job.perform_now
    assert import.reload.pending?, import.error
    get statement_import_url(import)
    assert_response :success
    assert_select "select[name='reviews[dbs:1111][account_id]']"
    assert_select "details summary", text: I18n.t("statement_imports.activities")
    patch statement_import_url(import), params: { reviews: { "dbs:1111" => { action: "match", account_id: accounts(:depository).id } } }
    post publish_statement_import_url(import)
    assert import.reload.importing?
  ensure
    file&.unlink
  end

  test "other family members cannot open an initiating user's import" do
    file = Tempfile.new([ "dbs-example", ".csv" ])
    file.write("Date,Amount,Currency\n2026-04-01,12,USD\n")
    file.rewind
    upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "dbs-example.csv", type: "text/csv")
    statement = AccountStatement.create_from_upload!(family: @user.family, account: nil, file: upload)
    import = StatementImport.create!(family: @user.family, initiating_user: @user, account_statement: statement)
    sign_in users(:family_member)
    get statement_import_url(import)
    assert_response :not_found
    get import_url(import)
    assert_response :not_found
  ensure
    file&.close!
  end
end
