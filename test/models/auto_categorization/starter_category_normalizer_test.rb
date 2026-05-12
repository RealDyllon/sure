require "test_helper"

class AutoCategorization::StarterCategoryNormalizerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @family.categories.destroy_all
  end

  test "normalizes category suggestions and rejects blank duplicate existing names" do
    @family.categories.create!(name: "Existing", color: "#22c55e", lucide_icon: "shapes")

    result = AutoCategorization::StarterCategoryNormalizer.call(
      family: @family,
      categories: [
        Provider::LlmConcept::SuggestedCategory.new(name: "  Groceries  ", parent_name: "Groceries", color: "bad", lucide_icon: "not-a-real-icon", rationale: "  Market rows  "),
        Provider::LlmConcept::SuggestedCategory.new(name: "groceries", parent_name: nil, color: "#22c55e", lucide_icon: "shopping-bag", rationale: nil),
        Provider::LlmConcept::SuggestedCategory.new(name: "Existing", parent_name: nil, color: "#22c55e", lucide_icon: "shapes", rationale: nil),
        Provider::LlmConcept::SuggestedCategory.new(name: " ", parent_name: nil, color: "#22c55e", lucide_icon: "shapes", rationale: nil)
      ]
    )

    assert_equal 1, result.size
    assert_equal "Groceries", result.first[:name]
    assert_nil result.first[:parent_name]
    assert_includes Category::COLORS, result.first[:color]
    assert_equal "shopping-bag", result.first[:lucide_icon]
    assert_equal "Market rows", result.first[:rationale]
    assert result.first[:selected]
  end
end
