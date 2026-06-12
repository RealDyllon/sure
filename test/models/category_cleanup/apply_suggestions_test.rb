require "test_helper"

class CategoryCleanup::ApplySuggestionsTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @family.categories.destroy_all
    @user = users(:empty)
    @run = CategoryCleanupRun.create!(
      family: @family,
      user: @user,
      status: :applying,
      provider_name: "Fake LLM",
      model: "test-model"
    )
  end

  test "applies selected suggestions in review order" do
    category_a = category!("Example A")
    category_b = category!("Example B")
    category_c = category!("Example C")

    first_suggestion = @run.suggestions.create!(
      id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      source_category: category_a,
      target_category: category_b,
      suggested_action: :merge,
      selected: true,
      created_at: 2.minutes.ago
    )
    second_suggestion = @run.suggestions.create!(
      id: "00000000-0000-4000-8000-000000000001",
      source_category: category_b,
      target_category: category_c,
      suggested_action: :merge,
      selected: true,
      created_at: 1.minute.ago
    )

    CategoryCleanup::ApplySuggestions.call(run: @run)

    assert_not Category.exists?(category_a.id)
    assert_not Category.exists?(category_b.id)
    assert Category.exists?(category_c.id)
    assert first_suggestion.reload.applied?
    assert second_suggestion.reload.applied?
    assert @run.reload.complete?
  end

  private
    def category!(name)
      @family.categories.create!(
        name: name,
        color: "#3b82f6",
        lucide_icon: "shapes"
      )
    end
end
