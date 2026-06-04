require "test_helper"

class CategoryCleanupSuggestionTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
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
