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

  test "merge bumps entries updated_at so entries_cache_version invalidates report caches" do
    account = @family.accounts.create!(
      name: "Example Checking",
      balance: 1_000,
      currency: "USD",
      accountable: Depository.new
    )

    travel_to 2.days.ago do
      txn = Transaction.create!(category: @source)
      Entry.create!(
        account: account,
        entryable: txn,
        amount: 50,
        currency: "USD",
        date: Date.current,
        name: "Example purchase"
      )
    end

    entry = Entry.where(entryable_type: "Transaction", entryable_id: @source.transactions.pluck(:id)).first
    original_entry_updated_at = entry.updated_at
    # Snapshot the raw maximum(entries.updated_at) — Family#entries_cache_version
    # memoizes per instance, so the real-world invalidation key is the SQL value
    # computed on the next request.
    original_max_entry_updated_at = @family.entries.maximum(:updated_at)

    travel_to 1.hour.from_now do
      suggestion = @run.suggestions.create!(
        source_category: @source,
        target_category: @target,
        suggested_action: :merge,
        selected: true
      )
      assert suggestion.apply!
    end

    assert entry.reload.updated_at > original_entry_updated_at,
      "Entry updated_at should be bumped by merge so Family#entries_cache_version invalidates"
    assert @family.entries.maximum(:updated_at) > original_max_entry_updated_at,
      "Family entries.maximum(:updated_at) should advance after merge so report caches miss"
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

  test "rename applies and records status atomically" do
    suggestion = @run.suggestions.create!(
      source_category: @source,
      suggested_action: :rename,
      new_name: "Renamed Example Root A",
      selected: true
    )

    assert suggestion.apply!

    assert_equal "Renamed Example Root A", @source.reload.name
    assert suggestion.reload.applied?
    assert_not_nil suggestion.applied_at
  end

  test "rename rolls back when status update fails" do
    suggestion = @run.suggestions.create!(
      source_category: @source,
      suggested_action: :rename,
      new_name: "Renamed Example Root A",
      selected: true
    )

    CategoryCleanupSuggestion.any_instance.stubs(:mark_applied!).raises(StandardError, "boom")

    assert_not suggestion.apply!

    assert_equal "Example Root A", @source.reload.name
    assert suggestion.reload.skipped?
    assert_equal "boom", suggestion.error
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

  test "merge syncs target parent budget when root is merged into subcategory without existing target row" do
    leaf_source = category!("Example Leaf Source") # no subcategories of its own
    budget = @family.budgets.create!(
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: @family.currency
    )
    budget.budget_categories.create!(category: leaf_source, budgeted_spending: 100, currency: @family.currency)
    budget.budget_categories.create!(category: @target, budgeted_spending: 40, currency: @family.currency)
    # No budget row for @target_child — this is the case the bug report flags.

    suggestion = @run.suggestions.create!(
      source_category: leaf_source,
      target_category: @target_child,
      suggested_action: :merge,
      selected: true
    )

    assert suggestion.apply!

    target_parent_budget = budget.budget_categories.find_by!(category: @target)
    target_child_budget = budget.budget_categories.find_by!(category: @target_child)
    # The source amount (100) must be added to the target parent budget on top
    # of the target child's existing amount (40).
    assert_equal 140, target_parent_budget.budgeted_spending
    assert_equal 100, target_child_budget.budgeted_spending
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

  test "reparent preserves target reserve when moving a budgeted root under a parent" do
    standalone_root = category!("Standalone Root")
    budget = @family.budgets.create!(
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: @family.currency
    )
    budget.budget_categories.create!(category: standalone_root, budgeted_spending: 100, currency: @family.currency)
    budget.budget_categories.create!(category: @target, budgeted_spending: 30, currency: @family.currency)

    suggestion = @run.suggestions.create!(
      source_category: standalone_root,
      parent_category: @target,
      suggested_action: :reparent,
      selected: true
    )

    assert suggestion.apply!

    assert_equal @target, standalone_root.reload.parent
    target_budget = budget.budget_categories.find_by!(category: @target)
    source_budget = budget.budget_categories.find_by!(category: standalone_root)
    assert_equal 130, target_budget.budgeted_spending
    assert_equal 100, source_budget.budgeted_spending
  end

  test "changing a suggestion action clears stale snapshot names" do
    suggestion = @run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )

    suggestion.update!(
      suggested_action: :rename,
      new_name: "Renamed Source",
      target_category: nil,
      parent_category: nil
    )

    assert_nil suggestion.target_category_name
    assert_nil suggestion.parent_category_name
    assert_equal "Renamed Source", suggestion.new_name
  end

  test "reparent rolls back budget and parent changes when restore fails" do
    leaf = category!("Leaf A")
    budget = @family.budgets.create!(
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: @family.currency
    )
    source_budget = budget.budget_categories.create!(category: leaf, budgeted_spending: 100, currency: @family.currency)

    suggestion = @run.suggestions.create!(
      source_category: leaf,
      parent_category: @target,
      suggested_action: :reparent,
      selected: true
    )

    CategoryCleanupSuggestion.any_instance.stubs(:restore_reparent_budgets!).raises(StandardError, "boom")

    assert_not suggestion.apply!

    assert_nil leaf.reload.parent
    assert_equal 100, source_budget.reload.budgeted_spending
    assert suggestion.reload.skipped?
    assert_equal "boom", suggestion.error
  end

  test "merge repoints rule actions and conditions from source to target" do
    rule = @family.rules.build(resource_type: "transaction")
    rule.actions.build(action_type: "set_transaction_category", value: @source.id)
    rule.conditions.build(condition_type: "transaction_category", operator: "=", value: @source.id)
    rule.save!

    suggestion = @run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )

    assert suggestion.apply!

    assert_equal @target.id, rule.reload.actions.first.value
    assert_equal @target.id, rule.reload.conditions.first.value
    assert_not Category.exists?(@source.id)
  end

  test "merge repoints compound rule sub-conditions" do
    unrelated = category!("Example Other")

    rule = @family.rules.build(name: "Compound Rule", resource_type: "transaction", active: true)
    parent_condition = rule.conditions.build(condition_type: "compound", operator: "and")
    parent_condition.sub_conditions.build(condition_type: "transaction_category", operator: "=", value: @source.id)
    parent_condition.sub_conditions.build(condition_type: "transaction_category", operator: "=", value: unrelated.id)
    rule.actions.build(action_type: "set_transaction_category", value: @source.id)
    rule.save!

    source_sub = parent_condition.sub_conditions.find { |sc| sc.value == @source.id }
    unrelated_sub = parent_condition.sub_conditions.find { |sc| sc.value == unrelated.id }

    suggestion = @run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )

    assert suggestion.apply!

    assert_equal @target.id, source_sub.reload.value
    assert_equal unrelated.id, unrelated_sub.reload.value
    assert_not Category.exists?(@source.id)
  end

  test "merge reassigns import category mappings from source to target" do
    import = @family.imports.create!(type: "TransactionImport", status: "pending")
    mapping = Import::CategoryMapping.create!(import: import, key: "Example Source", mappable: @source)

    suggestion = @run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )

    assert suggestion.apply!

    assert_equal @target, mapping.reload.mappable
    assert_not Category.exists?(@source.id)
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
