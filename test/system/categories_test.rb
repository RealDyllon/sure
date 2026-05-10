require "application_system_test_case"

class CategoriesTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include AutoCategorizationTestHelper
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
  end

  test "can create category" do
    visit categories_url
    click_link I18n.t("categories.new.new_category")
    fill_in "Name", with: "My Shiny New Category"
    click_button "Create Category"

    visit categories_url
    assert_text "My Shiny New Category"
  end

  test "trying to create a duplicate category fails" do
    visit categories_url
    click_link I18n.t("categories.new.new_category")
    fill_in "Name", with: categories(:food_and_drink).name
    click_button "Create Category"

    assert_text "Name has already been taken"
  end

  test "long category names truncate before the actions menu on mobile" do
    category = categories(:food_and_drink)
    category.update!(name: "Super Long Category Name That Should Stop Before The Menu Button On Mobile")

    page.current_window.resize_to(315, 643)

    visit categories_url

    row = find("##{ActionView::RecordIdentifier.dom_id(category)}")
    actions = row.find("[data-testid='category-actions'] button", visible: true)

    assert actions.visible?

    viewport_width = page.evaluate_script("window.innerWidth")
    page_scroll_width = page.evaluate_script("document.documentElement.scrollWidth")

    assert_operator page_scroll_width, :<=, viewport_width
  end

  test "shows AI auto categorize entry point when provider is configured" do
    stub_default_llm_provider

    visit categories_url

    assert_text "Auto-categorize"
  end

  test "launches AI wizard and reviews starter categories when no categories exist" do
    @user.family.accounts.each { |account| account.entries.delete_all }
    @user.family.categories.destroy_all
    create_transaction(account: accounts(:depository), name: "Example Market")
    stub_default_llm_provider(
      AutoCategorizationTestHelper::FakeLlmProvider.new(
        category_suggestions: [
          Provider::LlmConcept::SuggestedCategory.new(
            name: "Groceries",
            parent_name: nil,
            color: "#22c55e",
            lucide_icon: "shopping-bag",
            rationale: "Market transactions"
          )
        ]
      )
    )

    visit categories_url
    click_button "Auto-categorize"

    assert_text "AI auto-categorization"
    perform_enqueued_jobs
    click_on "Refresh"

    assert_text "Review starter categories"
    assert_field with: "Groceries"
  end

  test "launches AI wizard and applies reviewed transaction suggestion" do
    @user.family.accounts.each { |account| account.entries.delete_all }
    category = @user.family.categories.create!(name: "Example Coffee", color: "#22c55e", lucide_icon: "coffee")
    entry = create_transaction(account: accounts(:depository), name: "Example Cafe")
    provider = stub_default_llm_provider(
      AutoCategorizationTestHelper::FakeLlmProvider.new(
        categorizations: [
          Provider::LlmConcept::AutoCategorization.new(
            transaction_id: nil,
            category_name: category.name
          )
        ]
      )
    )

    visit categories_url
    click_button "Auto-categorize"
    assert_text "AI auto-categorization"

    run_transaction_id = AutoCategorizationRun.last.run_transactions.first.id
    provider.instance_variable_set(
      :@categorizations,
      [
        Provider::LlmConcept::AutoCategorization.new(
          transaction_id: run_transaction_id,
          category_name: category.name
        )
      ]
    )

    perform_enqueued_jobs
    click_on "Refresh"
    assert_text "Review transaction suggestions"
    assert_text "1 selected across all pages"

    click_button "Apply selected"
    assert_text "Applying reviewed categories"
    AutoCategorization::ApplySuggestions.call(run: AutoCategorizationRun.last.reload)
    click_on "Refresh"

    assert_text "1 applied"
    assert_equal category, entry.transaction.reload.category
  end
end
