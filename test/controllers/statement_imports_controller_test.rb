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
end
