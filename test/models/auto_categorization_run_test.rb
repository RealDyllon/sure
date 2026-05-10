require "test_helper"

class AutoCategorizationRunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AutoCategorizationTestHelper
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.accounts.each { |account| account.entries.delete_all }
    stub_default_llm_provider
  end

  test "run creator snapshots only transactions accessible to the initiating user" do
    accessible_entry = create_transaction(account: accounts(:depository), name: "Example Coffee")
    create_transaction(account: accounts(:investment), name: "Example Hidden")

    run = AutoCategorization::RunCreator.call(family: @family, user: users(:family_member))

    assert_equal 1, run.run_transactions.count
    assert_equal accessible_entry.transaction.id, run.run_transactions.first.transaction_id
    assert_equal "Example Coffee", run.run_transactions.first.snapshot["name"]
  end

  test "run creator records empty state without LLM generation when no eligible transactions exist" do
    run = AutoCategorization::RunCreator.call(family: @family, user: @user)

    assert run.empty?
    assert_equal 0, run.run_transactions.count
  end

  test "category suggestion creates matching existing category idempotently" do
    run = create_auto_categorization_run(family: @family, user: @user)
    existing = @family.categories.create!(name: "Example Utilities", color: "#3b82f6", lucide_icon: "lightbulb")

    suggestion = run.category_suggestions.create!(
      name: "example utilities",
      color: "#ffffff",
      lucide_icon: "zap",
      selected: true
    )

    assert_equal existing, suggestion.create_category!
    assert suggestion.reload.status_matched_existing?
  end

  test "apply updates only transaction category and locks category id" do
    entry = create_transaction(account: accounts(:depository), name: "Example Grocery")
    category = @family.categories.create!(name: "Example Groceries", color: "#22c55e", lucide_icon: "shopping-bag")
    run = create_auto_categorization_run(family: @family, user: @user, status: :applying)
    run_transaction = create_run_transaction(run, entry)
    run.suggestions.create!(
      run_transaction: run_transaction,
      selected_category: category,
      selected: true,
      status: :suggested
    )

    AutoCategorization::ApplySuggestions.call(run: run)

    assert_equal category, entry.transaction.reload.category
    assert entry.transaction.locked?(:category_id)
    assert_not entry.reload.user_modified?
    assert_empty entry.transaction.data_enrichments.where(source: "ai")
    assert run.reload.complete?
    assert_equal 1, run.applied_count
  end

  test "apply skips selected suggestion when selected category is missing" do
    entry = create_transaction(account: accounts(:depository), name: "Example Grocery")
    run = create_auto_categorization_run(family: @family, user: @user, status: :applying)
    run_transaction = create_run_transaction(run, entry)
    suggestion = run.suggestions.create!(
      run_transaction: run_transaction,
      selected: true,
      status: :suggested
    )

    AutoCategorization::ApplySuggestions.call(run: run)

    assert_nil entry.transaction.reload.category
    assert suggestion.reload.skipped?
    assert_equal "selected category missing", suggestion.error
    assert_equal 1, run.reload.skipped_count
  end

  test "apply skips selected suggestion when account becomes hidden" do
    entry = create_transaction(account: accounts(:depository), name: "Example Grocery")
    category = @family.categories.create!(name: "Example Groceries", color: "#22c55e", lucide_icon: "shopping-bag")
    run = create_auto_categorization_run(family: @family, user: @user, status: :applying)
    run_transaction = create_run_transaction(run, entry)
    suggestion = run.suggestions.create!(
      run_transaction: run_transaction,
      selected_category: category,
      selected: true,
      status: :suggested
    )
    entry.account.disable!

    AutoCategorization::ApplySuggestions.call(run: run)

    assert_nil entry.transaction.reload.category
    assert suggestion.reload.skipped?
    assert_equal "account hidden", suggestion.error
  end
end
