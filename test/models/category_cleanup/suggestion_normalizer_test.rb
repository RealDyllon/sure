require "test_helper"

class CategoryCleanup::SuggestionNormalizerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @family.categories.destroy_all
    @user = users(:empty)
    @source = category!("Example Root A")
    @child = category!("Example Child A", parent: @source)
    @target = category!("Example Root B")
    @run = CategoryCleanupRun.create!(
      family: @family,
      user: @user,
      status: :generating,
      provider_name: "Fake LLM",
      model: "test-model"
    )
  end

  test "selects valid actionable suggestions by default" do
    rows = CategoryCleanup::SuggestionNormalizer.call(
      run: @run,
      suggestions: [
        Provider::LlmConcept::CategoryCleanupSuggestion.new(
          action: "merge",
          source_category_id: @child.id,
          target_category_id: @target.id,
          new_name: nil,
          parent_category_id: nil,
          rationale: "The examples overlap",
          confidence: 0.9
        )
      ]
    )

    assert_equal 1, rows.size
    assert rows.first[:selected]
    assert_equal "suggested", rows.first[:status]
  end

  test "marks unsafe nesting suggestions for review" do
    rows = CategoryCleanup::SuggestionNormalizer.call(
      run: @run,
      suggestions: [
        Provider::LlmConcept::CategoryCleanupSuggestion.new(
          action: "reparent",
          source_category_id: @source.id,
          target_category_id: nil,
          new_name: nil,
          parent_category_id: @target.id,
          rationale: "Move this under a broader example",
          confidence: 0.9
        )
      ]
    )

    assert_equal 1, rows.size
    assert_not rows.first[:selected]
    assert_equal "needs_review", rows.first[:status]
    assert_equal "cannot move a parent category under another parent", rows.first[:error]
  end

  test "defaults missing confidence to low confidence" do
    rows = CategoryCleanup::SuggestionNormalizer.call(
      run: @run,
      suggestions: [
        {
          action: "merge",
          source_category_id: @child.id,
          target_category_id: @target.id,
          new_name: nil,
          parent_category_id: nil,
          rationale: "The examples overlap",
          confidence: nil
        }
      ]
    )

    assert_equal 1, rows.size
    assert_equal 0.0, rows.first[:confidence]
    assert_not rows.first[:selected]
    assert_equal "suggested", rows.first[:status]
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
