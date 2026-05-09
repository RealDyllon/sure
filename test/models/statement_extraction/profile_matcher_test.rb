require "test_helper"

class StatementExtraction::ProfileMatcherTest < ActiveSupport::TestCase
  test "matches extracted accounts to existing profiles" do
    account = accounts(:depository)
    profile = StatementProfile.create!(
      family: account.family,
      account: account,
      provider: "dbs",
      source_id: "dbs:00000018",
      source_name: "DBS 00000018",
      account_type: "Depository",
      account_subtype: "checking",
      currency: "SGD"
    )

    result = StatementExtraction::Result.new(
      provider: "dbs",
      file_type: "csv",
      accounts: [
        {
          "source_id" => "dbs:00000018",
          "name" => "DBS 00000018",
          "account_type" => "Depository",
          "currency" => "SGD"
        }
      ]
    )

    matched = StatementExtraction::ProfileMatcher.new(family: account.family, result: result).call

    assert_equal profile.id, matched.accounts.first["statement_profile_id"]
    assert_equal account.id, matched.accounts.first["matched_account_id"]
  end
end
