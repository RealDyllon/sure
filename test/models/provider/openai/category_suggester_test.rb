require "test_helper"

class Provider::Openai::CategorySuggesterTest < ActiveSupport::TestCase
  class FakeResponses
    def initialize(raw_text = nil)
      @raw_text = raw_text || {
        "categories" => [
          {
            "name" => "Groceries",
            "parent_name" => nil,
            "color" => "#22c55e",
            "lucide_icon" => "shopping-bag",
            "rationale" => "Market transactions"
          }
        ]
      }.to_json
    end

    def create(parameters:)
      {
        "output" => [
          {
            "type" => "message",
            "content" => [
              {
                "text" => @raw_text
              }
            ]
          }
        ],
        "usage" => { "total_tokens" => 10 }
      }
    end
  end

  class FakeClient
    def initialize(raw_text = nil)
      @raw_text = raw_text
    end

    def responses
      FakeResponses.new(@raw_text)
    end
  end

  class FakeGenericClient
    def initialize(content)
      @content = content
    end

    def chat(parameters:)
      {
        "choices" => [
          {
            "message" => {
              "content" => @content
            }
          }
        ],
        "usage" => { "total_tokens" => 10 }
      }
    end
  end

  test "suggests categories through native response parser" do
    result = Provider::Openai::CategorySuggester.new(
      FakeClient.new,
      model: "gpt-4.1",
      transactions: [ { id: "txn_1", description: "Example Market" } ],
      family: families(:dylan_family)
    ).suggest_categories

    assert_equal 1, result.size
    assert_equal "Groceries", result.first.name
    assert_equal "#22c55e", result.first.color
    assert_equal "shopping-bag", result.first.lucide_icon
  end

  test "llm concept exposes starter category contract" do
    assert_equal %i[name parent_name color lucide_icon rationale], Provider::LlmConcept::SuggestedCategory.members
    assert_respond_to Provider::Openai.new("test-token"), :suggest_categories
  end

  test "raises sanitized provider error for invalid native JSON" do
    error = assert_raises Provider::Openai::Error do
      Provider::Openai::CategorySuggester.new(
        FakeClient.new("not json"),
        model: "gpt-4.1",
        transactions: [ { id: "txn_1", description: "Example Market" } ],
        family: families(:dylan_family)
      ).suggest_categories
    end

    assert_match "Invalid JSON", error.message
  end

  test "parses generic responses from fenced JSON" do
    result = Provider::Openai::CategorySuggester.new(
      FakeGenericClient.new(<<~JSON),
        ```json
        {"categories":[{"name":"Utilities","parent_name":null,"color":"#3b82f6","lucide_icon":"lightbulb","rationale":"Bills"}]}
        ```
      JSON
      model: "gpt-4.1",
      transactions: [ { id: "txn_1", description: "Example Power" } ],
      custom_provider: true,
      family: families(:dylan_family),
      json_mode: Provider::Openai::AutoCategorizer::JSON_MODE_NONE
    ).suggest_categories

    assert_equal 1, result.size
    assert_equal "Utilities", result.first.name
    assert_equal "lightbulb", result.first.lucide_icon
  end

  test "parses generic responses from a bare JSON array" do
    result = Provider::Openai::CategorySuggester.new(
      FakeGenericClient.new(
        [
          {
            "name" => "Utilities",
            "parent_name" => nil,
            "color" => "#3b82f6",
            "lucide_icon" => "lightbulb",
            "rationale" => "Bills"
          }
        ].to_json
      ),
      model: "gpt-4.1",
      transactions: [ { id: "txn_1", description: "Example Power" } ],
      custom_provider: true,
      family: families(:dylan_family),
      json_mode: Provider::Openai::AutoCategorizer::JSON_MODE_NONE
    ).suggest_categories

    assert_equal 1, result.size
    assert_equal "Utilities", result.first.name
    assert_equal "lightbulb", result.first.lucide_icon
  end
end
