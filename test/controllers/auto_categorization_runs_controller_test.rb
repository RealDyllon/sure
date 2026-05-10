require "test_helper"

class AutoCategorizationRunsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include AutoCategorizationTestHelper
  include EntriesTestHelper

  setup do
    ensure_tailwind_build
    @user = users(:family_admin)
    @family = @user.family
    @family.accounts.each { |account| account.entries.delete_all }
    sign_in @user
  end

  test "start requires configured provider and creates no run without one" do
    Provider::Registry.stubs(:default_llm_provider).returns(nil)

    assert_no_difference "AutoCategorizationRun.count" do
      post auto_categorization_runs_url
    end

    assert_redirected_to categories_url
  end

  test "start creates run and queues generation" do
    stub_default_llm_provider
    create_transaction(account: accounts(:depository), name: "Example Cafe")

    assert_difference "AutoCategorizationRun.count", 1 do
      assert_enqueued_with(job: AutoCategorizationGenerateJob) do
        post auto_categorization_runs_url
      end
    end

    assert_redirected_to auto_categorization_run_url(AutoCategorizationRun.last)
  end

  test "start with no categories queues starter category generation" do
    stub_default_llm_provider
    @family.categories.destroy_all
    create_transaction(account: accounts(:depository), name: "Example Market")

    assert_enqueued_with(job: AutoCategorizationGenerateJob) do
      post auto_categorization_runs_url
    end

    assert AutoCategorizationRun.last.suggesting_categories?
  end

  test "retry requires provider configuration" do
    run = create_auto_categorization_run(family: @family, user: @user, status: :failed)
    Provider::Registry.stubs(:default_llm_provider).returns(nil)

    post retry_auto_categorization_run_url(run)

    assert_redirected_to auto_categorization_run_url(run)
    assert_equal "AI configuration is required before retrying.", flash[:alert]
  end

  test "updates starter category suggestion" do
    run = create_auto_categorization_run(family: @family, user: @user, status: :reviewing_categories)
    suggestion = run.category_suggestions.create!(
      name: "Example Food",
      color: "#22c55e",
      lucide_icon: "utensils",
      selected: true
    )

    patch category_suggestion_auto_categorization_run_url(run, suggestion),
      params: {
        auto_categorization_category_suggestion: {
          name: "Example Dining",
          selected: "0",
          color: "#3b82f6",
          lucide_icon: "coffee"
        }
      }

    assert_redirected_to auto_categorization_run_url(run)
    assert_equal "Example Dining", suggestion.reload.name
    assert_not suggestion.selected?
  end

  test "manually adds starter category suggestion" do
    run = create_auto_categorization_run(family: @family, user: @user, status: :reviewing_categories)

    assert_difference "AutoCategorizationCategorySuggestion.count", 1 do
      post category_suggestions_auto_categorization_run_url(run),
        params: {
          auto_categorization_category_suggestion: {
            name: "Example Bills",
            color: "#3b82f6",
            lucide_icon: "receipt"
          }
        }
    end

    assert_redirected_to auto_categorization_run_url(run)
    assert AutoCategorizationCategorySuggestion.last.selected?
  end

  test "bootstrap categories creates defaults and queues transaction generation" do
    @family.categories.destroy_all
    run = create_auto_categorization_run(family: @family, user: @user, status: :reviewing_categories)

    assert_enqueued_with(job: AutoCategorizationGenerateJob) do
      post bootstrap_categories_auto_categorization_run_url(run)
    end

    assert @family.categories.exists?
    assert_redirected_to auto_categorization_run_url(run)
  end

  test "create selected starter categories queues category creation" do
    run = create_auto_categorization_run(family: @family, user: @user, status: :reviewing_categories)
    run.category_suggestions.create!(
      name: "Example Food",
      color: "#22c55e",
      lucide_icon: "utensils",
      selected: true
    )

    assert_enqueued_with(job: AutoCategorizationCreateCategoriesJob) do
      post create_categories_auto_categorization_run_url(run)
    end

    assert_redirected_to auto_categorization_run_url(run)
  end

  test "updates transaction suggestion and preserves review params" do
    category = @family.categories.create!(name: "Example Coffee", color: "#22c55e", lucide_icon: "coffee")
    entry = create_transaction(account: accounts(:depository), name: "Example Cafe")
    run = create_auto_categorization_run(family: @family, user: @user, status: :reviewing_transactions)
    run_transaction = create_run_transaction(run, entry)
    suggestion = run.suggestions.create!(run_transaction: run_transaction, status: :needs_review)

    patch suggestion_auto_categorization_run_url(run, suggestion),
      params: {
        selected: "true",
        selected_category_id: category.id,
        q: "Cafe",
        page: 2,
        per_page: 20
      }

    assert_redirected_to auto_categorization_run_url(run, q: "Cafe", page: "2", per_page: "20")
    assert suggestion.reload.selected?
    assert_equal category, suggestion.selected_category
  end

  test "zero selected starter categories does not queue category creation" do
    run = create_auto_categorization_run(family: @family, user: @user, status: :reviewing_categories)
    run.category_suggestions.create!(
      name: "Example Food",
      color: "#22c55e",
      lucide_icon: "utensils",
      selected: false
    )

    assert_no_enqueued_jobs only: AutoCategorizationCreateCategoriesJob do
      post create_categories_auto_categorization_run_url(run)
    end

    assert_redirected_to auto_categorization_run_url(run)
  end

  test "apply queues selected suggestions and preserves review params" do
    category = @family.categories.create!(name: "Example Category", color: "#22c55e", lucide_icon: "shapes")
    entry = create_transaction(account: accounts(:depository), name: "Example Cafe")
    run = create_auto_categorization_run(family: @family, user: @user, status: :reviewing_transactions)
    run_transaction = create_run_transaction(run, entry)
    run.suggestions.create!(
      run_transaction: run_transaction,
      selected_category: category,
      selected: true,
      status: :suggested
    )

    assert_enqueued_with(job: AutoCategorizationApplyJob) do
      post apply_auto_categorization_run_url(run, q: "Cafe", per_page: 20)
    end

    assert_redirected_to auto_categorization_run_url(run, q: "Cafe", per_page: "20")
  end

  test "review table paginates large suggestion sets and clamps per page" do
    category = @family.categories.create!(name: "Example Category", color: "#22c55e", lucide_icon: "shapes")
    run = create_auto_categorization_run(family: @family, user: @user, status: :reviewing_transactions)

    125.times do |index|
      run_transaction = run.run_transactions.create!(
        captured_at: Time.current,
        snapshot: {
          "date" => Date.current.iso8601,
          "name" => "Example Transaction #{index}",
          "description" => "Example Transaction #{index}",
          "amount" => "10.00",
          "currency" => "USD",
          "classification" => "expense"
        }
      )
      run.suggestions.create!(
        run_transaction: run_transaction,
        selected_category: category,
        selected: true,
        status: :suggested
      )
    end

    get auto_categorization_run_url(run, per_page: 20, q: "Example")

    assert_response :success
    assert_select "tbody tr", count: 20
    assert_includes response.body, "125 selected across all pages"
  end
end
