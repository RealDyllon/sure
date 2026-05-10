require "test_helper"

class AutoCategorization::GenerateSuggestionsTest < ActiveSupport::TestCase
  include AutoCategorizationTestHelper
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.accounts.each { |account| account.entries.delete_all }
  end

  test "no-categories generation uses starter category provider and not auto categorize" do
    @family.categories.destroy_all
    entry = create_transaction(account: accounts(:depository), name: "Example Market")
    run = create_auto_categorization_run(family: @family, user: @user, status: :suggesting_categories)
    create_run_transaction(run, entry)

    provider = stub_default_llm_provider(
      AutoCategorizationTestHelper::FakeLlmProvider.new(
        category_suggestions: [
          Provider::LlmConcept::SuggestedCategory.new(
            name: "Groceries",
            parent_name: nil,
            color: "#22c55e",
            lucide_icon: "shopping-bag",
            rationale: "Market purchases"
          )
        ]
      )
    )

    AutoCategorization::GenerateSuggestions.call(run: run)

    assert_equal 1, provider.suggest_category_calls.size
    assert_empty provider.auto_categorize_calls
    assert run.reload.reviewing_categories?
    assert_equal "Groceries", run.category_suggestions.first.name
  end

  test "transaction generation persists no-match rows for omitted provider results" do
    category = @family.categories.create!(name: "Example Coffee", color: "#22c55e", lucide_icon: "coffee")
    first_entry = create_transaction(account: accounts(:depository), name: "Example Cafe")
    second_entry = create_transaction(account: accounts(:depository), name: "Example Unknown")
    run = create_auto_categorization_run(family: @family, user: @user, status: :suggesting_transactions)
    first_snapshot = create_run_transaction(run, first_entry)
    second_snapshot = create_run_transaction(run, second_entry)

    stub_default_llm_provider(
      AutoCategorizationTestHelper::FakeLlmProvider.new(
        categorizations: [
          Provider::LlmConcept::AutoCategorization.new(
            transaction_id: first_snapshot.id,
            category_name: category.name
          )
        ]
      )
    )

    AutoCategorization::GenerateSuggestions.call(run: run)

    assert run.reload.reviewing_transactions?
    assert_equal 2, run.suggestions.count
    assert run.suggestions.find_by(run_transaction: first_snapshot).selected?
    assert_not run.suggestions.find_by(run_transaction: second_snapshot).selected?
    assert run.suggestions.find_by(run_transaction: second_snapshot).needs_review?
  end

  test "category generation does not persist suggestions after losing job ownership" do
    @family.categories.destroy_all
    entry = create_transaction(account: accounts(:depository), name: "Example Market")
    run = create_auto_categorization_run(family: @family, user: @user, status: :suggesting_categories)
    create_run_transaction(run, entry)
    run.update!(processing_progress: { "job_id" => "old-job", "phase" => "suggesting_categories" })

    stub_default_llm_provider(
      AutoCategorizationTestHelper::FakeLlmProvider.new(
        category_suggestions: [
          Provider::LlmConcept::SuggestedCategory.new(
            name: "Groceries",
            parent_name: nil,
            color: "#22c55e",
            lucide_icon: "shopping-bag",
            rationale: "Market purchases"
          )
        ],
        on_suggest_categories: -> {
          run.update!(processing_progress: run.processing_progress.merge("job_id" => "newer-job"))
        }
      )
    )

    AutoCategorization::GenerateSuggestions.call(run: run, job_id: "old-job")

    assert_equal "newer-job", run.reload.processing_progress["job_id"]
    assert_equal 0, run.category_suggestions.count
    assert run.suggesting_categories?
  end

  test "transaction generation does not persist batch after losing job ownership" do
    category = @family.categories.create!(name: "Example Coffee", color: "#22c55e", lucide_icon: "coffee")
    entry = create_transaction(account: accounts(:depository), name: "Example Cafe")
    run = create_auto_categorization_run(family: @family, user: @user, status: :suggesting_transactions)
    snapshot = create_run_transaction(run, entry)
    run.update!(processing_progress: { "job_id" => "old-job", "phase" => "suggesting_transactions" })

    stub_default_llm_provider(
      AutoCategorizationTestHelper::FakeLlmProvider.new(
        categorizations: [
          Provider::LlmConcept::AutoCategorization.new(
            transaction_id: snapshot.id,
            category_name: category.name
          )
        ],
        on_auto_categorize: -> {
          run.update!(processing_progress: run.processing_progress.merge("job_id" => "newer-job"))
        }
      )
    )

    AutoCategorization::GenerateSuggestions.call(run: run, job_id: "old-job")

    assert_equal "newer-job", run.reload.processing_progress["job_id"]
    assert_equal 1, run.suggestions.count
    assert run.suggestions.first.pending_generation?
    assert_not snapshot.reload.generated?
  end
end
