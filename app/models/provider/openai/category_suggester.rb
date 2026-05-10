class Provider::Openai::CategorySuggester
  include Provider::Openai::Concerns::UsageRecorder

  attr_reader :client, :model, :transactions, :custom_provider, :langfuse_trace, :family, :json_mode

  def initialize(client, model: "", transactions: [], custom_provider: false, langfuse_trace: nil, family: nil, json_mode: nil)
    @client = client
    @model = model
    @transactions = transactions
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
    @json_mode = json_mode || Provider::Openai::AutoCategorizer::JSON_MODE_AUTO
  end

  def suggest_categories
    custom_provider ? suggest_categories_generic : suggest_categories_native
  end

  private
    SuggestedCategory = Provider::LlmConcept::SuggestedCategory

    def suggest_categories_native
      span = langfuse_trace&.span(name: "suggest_categories_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        transactions: transactions
      })

      response = client.responses.create(parameters: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        input: [ { role: "developer", content: developer_message } ],
        text: {
          format: {
            type: "json_schema",
            name: "suggest_personal_finance_categories",
            strict: true,
            schema: json_schema
          }
        },
        instructions: instructions
      })

      result = build_response(extract_categories_native(response))
      record_usage(
        model.presence || Provider::Openai::DEFAULT_MODEL,
        response.dig("usage"),
        operation: "suggest_categories",
        metadata: { transaction_count: transactions.size }
      )
      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def suggest_categories_generic
      mode = json_mode == Provider::Openai::AutoCategorizer::JSON_MODE_AUTO ? Provider::Openai::AutoCategorizer::JSON_MODE_STRICT : json_mode
      suggest_categories_with_mode(mode)
    rescue Faraday::BadRequestError => e
      if mode == Provider::Openai::AutoCategorizer::JSON_MODE_STRICT
        Rails.logger.warn("Strict JSON mode failed, falling back to none mode: #{e.message}")
        suggest_categories_with_mode(Provider::Openai::AutoCategorizer::JSON_MODE_NONE)
      else
        raise
      end
    end

    def suggest_categories_with_mode(mode)
      span = langfuse_trace&.span(name: "suggest_categories_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        transactions: transactions,
        json_mode: mode
      })

      params = {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: developer_message_for_generic }
        ]
      }

      case mode
      when Provider::Openai::AutoCategorizer::JSON_MODE_STRICT
        params[:response_format] = {
          type: "json_schema",
          json_schema: {
            name: "suggest_personal_finance_categories",
            strict: true,
            schema: json_schema
          }
        }
      when Provider::Openai::AutoCategorizer::JSON_MODE_OBJECT
        params[:response_format] = { type: "json_object" }
      end

      response = client.chat(parameters: params)
      result = build_response(extract_categories_generic(response))
      record_usage(
        model.presence || Provider::Openai::DEFAULT_MODEL,
        response.dig("usage"),
        operation: "suggest_categories",
        metadata: { transaction_count: transactions.size, json_mode: mode }
      )
      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def build_response(categories)
      Array(categories).map do |category|
        SuggestedCategory.new(
          name: category["name"],
          parent_name: category["parent_name"],
          color: category["color"],
          lucide_icon: category["lucide_icon"],
          rationale: category["rationale"]
        )
      end
    end

    def extract_categories_native(response)
      message_output = response["output"]&.find { |o| o["type"] == "message" }
      raw = message_output&.dig("content", 0, "text")

      raise Provider::Openai::Error, "No message content found in response" if raw.nil?

      JSON.parse(raw).dig("categories")
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in category suggestions: #{e.message}"
    end

    def extract_categories_generic(response)
      raw = response.dig("choices", 0, "message", "content")
      parsed = parse_json_flexibly(raw)
      categories = if parsed.is_a?(Array)
        parsed
      elsif parsed.is_a?(Hash)
        parsed["categories"] || parsed["suggestions"]
      end

      raise Provider::Openai::Error, "Could not find category suggestions in response" if categories.nil?

      categories.map do |category|
        {
          "name" => category["name"] || category["category_name"] || category["category"],
          "parent_name" => category["parent_name"] || category["parent"],
          "color" => category["color"],
          "lucide_icon" => category["lucide_icon"] || category["icon"],
          "rationale" => category["rationale"] || category["reason"]
        }
      end
    end

    def parse_json_flexibly(raw)
      return {} if raw.blank?

      cleaned = raw.to_s.gsub(/<think>[\s\S]*?<\/think>/m, "").strip
      JSON.parse(cleaned)
    rescue JSON::ParserError
      if cleaned =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
        return JSON.parse($1)
      end

      if cleaned =~ /(\{[\s\S]*\})/m
        return JSON.parse($1)
      end

      raise Provider::Openai::Error, "Could not parse JSON from response"
    end

    def json_schema
      {
        type: "object",
        properties: {
          categories: {
            type: "array",
            description: "Starter personal finance categories suggested from transactions",
            items: {
              type: "object",
              properties: {
                name: { type: "string", description: "Category name" },
                parent_name: { type: [ "string", "null" ], description: "Optional parent category name" },
                color: { type: "string", description: "Hex color, e.g. #3b82f6" },
                lucide_icon: { type: "string", description: "Lucide icon name" },
                rationale: { type: "string", description: "Short reason this category is useful" }
              },
              required: [ "name", "parent_name", "color", "lucide_icon", "rationale" ],
              additionalProperties: false
            }
          }
        },
        required: [ "categories" ],
        additionalProperties: false
      }
    end

    def instructions
      <<~INSTRUCTIONS.strip_heredoc
        You are helping set up starter categories for a personal finance app.
        Review the transactions and suggest a concise category set that would help categorize them.

        Rules:
        - Return JSON only.
        - Suggest broad, user-friendly categories.
        - Avoid duplicate or near-duplicate category names.
        - Use parent_name only when a child category is meaningfully more specific.
        - Do not create more than two hierarchy levels.
        - Prefer Lucide icon names that match the category.
        - Use hex colors.
      INSTRUCTIONS
    end

    def developer_message
      <<~MESSAGE.strip_heredoc
        Suggest starter categories for these transactions:

        ```json
        #{transactions.to_json}
        ```
      MESSAGE
    end

    def developer_message_for_generic
      <<~MESSAGE.strip_heredoc
        TRANSACTIONS:
        #{transactions.to_json}

        Respond with ONLY JSON:
        {"categories":[{"name":"Food & Drink","parent_name":null,"color":"#f97316","lucide_icon":"utensils","rationale":"Restaurants and dining transactions"}]}
      MESSAGE
    end
end
