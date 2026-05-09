require "test_helper"

class StatementExtraction::ProfileMatcherTest < ActiveSupport::TestCase
  test "matches extracted accounts to existing profiles" do
    account = accounts(:depository)
    profile = StatementProfile.create!(
      family: account.family,
      account: account,
      provider: "dbs",
      source_id: "dbs:5678",
      source_name: "DBS 5678",
      account_type: "Depository",
      account_subtype: "checking",
      currency: "SGD"
    )

    result = StatementExtraction::Result.new(
      provider: "dbs",
      file_type: "csv",
      accounts: [
        {
          "source_id" => "dbs:5678",
          "name" => "DBS 5678",
          "account_type" => "Depository",
          "currency" => "SGD"
        }
      ]
    )

    matched = StatementExtraction::ProfileMatcher.new(family: account.family, result: result).call

    assert_equal profile.id, matched.accounts.first["statement_profile_id"]
    assert_equal account.id, matched.accounts.first["matched_account_id"]
  end

  test "suggests a unique compatible manual account by provider and last four" do
    account = accounts(:depository)
    account.update!(name: "DBS Multiplier 5678", currency: "SGD")

    result = StatementExtraction::Result.new(
      provider: "dbs",
      file_type: "pdf",
      accounts: [
        {
          "source_id" => "dbs:5678",
          "name" => "DBS Multiplier Account",
          "account_type" => "Depository",
          "subtype" => "checking",
          "currency" => "SGD"
        }
      ]
    )

    matched = StatementExtraction::ProfileMatcher.new(family: account.family, result: result).call
    review = matched.accounts.first["review"]

    assert_equal "match", review["action"]
    assert_equal account.id, review["account_id"]
    assert_equal "Depository", review["account_type"]
    assert_equal "checking", review["account_subtype"]
    assert_equal "DBS Multiplier 5678", review["account_name"]
    assert_equal "SGD", review["currency"]
  end

  test "does not suggest an account when heuristic matches are ambiguous" do
    family = accounts(:depository).family
    Account.create_and_sync(
      {
        family: family,
        name: "DBS Current 5678",
        balance: 100,
        currency: "SGD",
        accountable_type: "Depository",
        accountable_attributes: { subtype: "checking" }
      },
      skip_initial_sync: true
    )
    Account.create_and_sync(
      {
        family: family,
        name: "DBS Savings 5678",
        balance: 200,
        currency: "SGD",
        accountable_type: "Depository",
        accountable_attributes: { subtype: "savings" }
      },
      skip_initial_sync: true
    )

    result = StatementExtraction::Result.new(
      provider: "dbs",
      file_type: "pdf",
      accounts: [
        {
          "source_id" => "dbs:5678",
          "name" => "DBS Account",
          "account_type" => "Depository",
          "currency" => "SGD"
        }
      ]
    )

    matched = StatementExtraction::ProfileMatcher.new(family: family, result: result).call

    assert_nil matched.accounts.first["review"]
    assert_nil matched.accounts.first["matched_account_id"]
  end
end
