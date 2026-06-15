require "test_helper"

class CategoryCleanupSuggestionTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @family.budgets.destroy_all
    @family.categories.destroy_all
    @user = users(:empty)
    @source = category!("Example Root A")
    @child = category!("Example Child A", parent: @source)
    @target = category!("Example Root B")
    @target_child = category!("Example Child B", parent: @target)
    @run = CategoryCleanupRun.create!(
      family: @family,
      user: @user,
      status: :reviewing,
      provider_name: "Fake LLM",
      model: "test-model"
    )
  end

  test "merge moves subcategories when target is root category" do
    suggestion = @run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )

    assert suggestion.apply!

    assert_nil Category.find_by(id: @source.id)
    assert_equal @target, @child.reload.parent
    assert suggestion.reload.applied?
  end

  test "merge skips parent category into subcategory" do
    suggestion = @run.suggestions.create!(
      source_category: @source,
      target_category: @target_child,
      suggested_action: :merge,
      selected: true
    )

    assert_not suggestion.apply!

    assert Category.exists?(@source.id)
    assert_equal @source, @child.reload.parent
    assert suggestion.reload.skipped?
    assert_equal "cannot merge a parent category into a subcategory", suggestion.error
  end

  test "merge preserves and deduplicates budget category allocations" do
    budget = @family.budgets.create!(
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: @family.currency
    )
    budget.budget_categories.create!(category: @source, budgeted_spending: 100, currency: @family.currency)
    budget.budget_categories.create!(category: @target, budgeted_spending: 50, currency: @family.currency)
    suggestion = @run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )

    assert suggestion.apply!

    target_budget_category = budget.budget_categories.find_by!(category: @target)
    assert_equal 150, target_budget_category.budgeted_spending
    assert_not budget.budget_categories.exists?(category: @source)
  end

  test "reparent skips moving parent category under another parent" do
    suggestion = @run.suggestions.create!(
      source_category: @source,
      parent_category: @target,
      suggested_action: :reparent,
      selected: true
    )

    assert_not suggestion.apply!

    assert_nil @source.reload.parent
    assert_equal @source, @child.reload.parent
    assert suggestion.reload.skipped?
  end

  test "rename skips duplicate category name" do
    suggestion = @run.suggestions.create!(
      source_category: @source,
      suggested_action: :rename,
      new_name: @target.name,
      selected: true
    )

    assert_not suggestion.apply!

    assert_equal "Example Root A", @source.reload.name
    assert_equal "category name already exists", suggestion.reload.error
  end

  test "merge does not double-count budget when child merges into parent" do
    budget = @family.budgets.create!(
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: @family.currency
    )
    budget.budget_categories.create!(category: @source, budgeted_spending: 100, currency: @family.currency)
    budget.budget_categories.create!(category: @child, budgeted_spending: 50, currency: @family.currency)

    suggestion = @run.suggestions.create!(
      source_category: @child,
      target_category: @source,
      suggested_action: :merge,
      selected: true
    )

    assert suggestion.apply!

    parent_budget_category = budget.budget_categories.find_by!(category: @source)
    assert_equal 100, parent_budget_category.budgeted_spending
    assert_not budget.budget_categories.exists?(category: @child)
  end

  test "reparent applies explicit move to root" do
    @child.update!(parent: @source)
    suggestion = @run.suggestions.create!(
      source_category: @child,
      suggested_action: :reparent,
      metadata: { "reparent_intended_root" => true, "reparent_intended_parent_category_id" => nil },
      selected: true
    )

    assert suggestion.apply!

    assert_nil @child.reload.parent
    assert suggestion.reload.applied?
  end

  test "reparent skips when intended parent is missing" do
    suggestion = @run.suggestions.create!(
      source_category: @source,
      suggested_action: :reparent,
      metadata: { "reparent_intended_root" => false, "reparent_intended_parent_category_id" => "missing-id" },
      selected: true
    )

    assert_not suggestion.apply!

    assert_nil @source.reload.parent
    assert suggestion.reload.skipped?
    assert_equal "parent category missing", suggestion.error
  end

  test "reparent resyncs subcategory budgets across old and new parents" do
    budget = @family.budgets.create!(
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: @family.currency
    )
    budget.budget_categories.create!(category: @source, budgeted_spending: 100, currency: @family.currency)
    budget.budget_categories.create!(category: @child, budgeted_spending: 50, currency: @family.currency)
    budget.budget_categories.create!(category: @target, budgeted_spending: 30, currency: @family.currency)

    suggestion = @run.suggestions.create!(
      source_category: @child,
      parent_category: @target,
      suggested_action: :reparent,
      selected: true
    )

    assert suggestion.apply!

    assert_equal @target, @child.reload.parent
    source_budget = budget.budget_categories.find_by!(category: @source)
    target_budget = budget.budget_categories.find_by!(category: @target)
    child_budget = budget.budget_categories.find_by!(category: @child)
    assert_equal 50, source_budget.budgeted_spending
    assert_equal 80, target_budget.budgeted_spending
    assert_equal 50, child_budget.budgeted_spending
  end

  private
    def category!(name, parent: nil)
      @family.categories.create!(
        name: name,
        parent: parent,
        color: "#3b82f6",
        lucide_icon: "shapes"
      )
    end
end
