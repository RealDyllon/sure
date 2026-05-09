require "test_helper"

class StatementImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
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

  test "review page preselects matched manual account but still requires publish review" do
    ensure_tailwind_build

    account = accounts(:depository)
    account.update!(name: "DBS Multiplier 00000018", currency: "SGD")

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
            "source_id" => "dbs:00000018",
            "name" => "Fixture Account 3",
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

    get import_url(statement_import)

    assert_response :success
    assert_select "select[name='statement_import[accounts][0][account_id]'] option[selected][value='#{account.id}']", text: account.name
    assert_select "form[action='#{import_path(statement_import)}']"
    assert_select "form[action='#{publish_import_path(statement_import)}']", 0
  end
end
