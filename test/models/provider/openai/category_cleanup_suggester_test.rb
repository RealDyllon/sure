require "test_helper"

class Provider::Openai::CategoryCleanupSuggesterTest < ActiveSupport::TestCase
  CategoryResponseClient = Struct.new(:response, :last_parameters) do
    def responses = self

    def create(parameters:)
      self.last_parameters = parameters
      response
    end
  end

  CategoryChatClient = Struct.new(:response, :last_parameters) do
    def chat(parameters:)
      self.last_parameters = parameters
      response
    end
  end

  test "parses native category cleanup suggestions" do
    client = CategoryResponseClient.new({
      "output" => [
        {
          "type" => "message",
          "content" => [
            {
              "text" => {
                "suggestions" => [
                  {
                    "action" => "merge",
                    "source_category_id" => "cat_child_a",
                    "target_category_id" => "cat_child_b",
                    "new_name" => nil,
                    "parent_category_id" => nil,
                    "rationale" => "Example child categories overlap.",
                    "confidence" => 0.92
                  }
                ]
              }.to_json
            }
          ]
        }
      ],
      "usage" => { "input_tokens" => 12, "output_tokens" => 8, "total_tokens" => 20 }
    })

    suggestions = Provider::Openai::CategoryCleanupSuggester.new(
      client,
      model: "gpt-test",
      categories: category_payload,
      custom_provider: false
    ).organize_categories

    assert_equal 1, suggestions.size
    assert_equal "merge", suggestions.first.action
    assert_equal "cat_child_a", suggestions.first.source_category_id
    assert_equal "cat_child_b", suggestions.first.target_category_id
    assert_equal "organize_personal_finance_categories", client.last_parameters.dig(:text, :format, :name)
  end

  test "parses generic fenced category cleanup suggestions" do
    client = CategoryChatClient.new({
      "choices" => [
        {
          "message" => {
            "content" => <<~JSON
              ```json
              {
                "suggestions": [
                  {
                    "suggested_action": "rename",
                    "source_id": "cat_root_a",
                    "target_id": null,
                    "name": "Example Root Renamed",
                    "new_parent_category_id": null,
                    "reason": "Example root category name is clearer.",
                    "confidence": 0.81
                  }
                ]
              }
              ```
            JSON
          }
        }
      ],
      "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15 }
    })

    suggestions = Provider::Openai::CategoryCleanupSuggester.new(
      client,
      model: "gpt-test",
      categories: category_payload,
      custom_provider: true,
      json_mode: Provider::Openai::AutoCategorizer::JSON_MODE_NONE
    ).organize_categories

    assert_equal 1, suggestions.size
    assert_equal "rename", suggestions.first.action
    assert_equal "cat_root_a", suggestions.first.source_category_id
    assert_equal "Example Root Renamed", suggestions.first.new_name
    assert_nil client.last_parameters[:response_format]
  end

  private
    def category_payload
      [
        { "id" => "cat_root_a", "name" => "Example Root A", "parent_id" => nil, "path" => "Example Root A" },
        { "id" => "cat_root_b", "name" => "Example Root B", "parent_id" => nil, "path" => "Example Root B" },
        { "id" => "cat_child_a", "name" => "Example Child A", "parent_id" => "cat_root_a", "path" => "Example Root A / Example Child A" },
        { "id" => "cat_child_b", "name" => "Example Child B", "parent_id" => "cat_root_b", "path" => "Example Root B / Example Child B" }
      ]
    end
end
