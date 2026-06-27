class Provider::Openai::CategoryCleanupSuggester
  include Provider::Openai::Concerns::UsageRecorder

  attr_reader :client, :model, :categories, :custom_provider, :langfuse_trace, :family, :json_mode

  def initialize(client, model: "", categories: [], custom_provider: false, langfuse_trace: nil, family: nil, json_mode: nil)
    @client = client
    @model = model
    @categories = categories
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
    @json_mode = json_mode || Provider::Openai::AutoCategorizer::JSON_MODE_AUTO
  end

  def organize_categories
    custom_provider ? organize_categories_generic : organize_categories_native
  end

  private
    CleanupSuggestion = Provider::LlmConcept::CategoryCleanupSuggestion

    def organize_categories_native
      span = langfuse_trace&.span(name: "organize_categories_api_call", input: {
        model: effective_model,
        categories: categories
      })

      response = client.responses.create(parameters: {
        model: effective_model,
        input: [ { role: "developer", content: developer_message } ],
        text: {
          format: {
            type: "json_schema",
            name: "organize_personal_finance_categories",
            strict: true,
            schema: json_schema
          }
        },
        instructions: instructions
      })

      result = build_response(extract_suggestions_native(response))
      record_usage(
        effective_model,
        response.dig("usage"),
        operation: "organize_categories",
        metadata: { category_count: categories.size }
      )
      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def organize_categories_generic
      mode = json_mode == Provider::Openai::AutoCategorizer::JSON_MODE_AUTO ? Provider::Openai::AutoCategorizer::JSON_MODE_STRICT : json_mode
      organize_categories_with_mode(mode)
    rescue Faraday::BadRequestError => e
      if mode == Provider::Openai::AutoCategorizer::JSON_MODE_STRICT
        Rails.logger.warn("Strict JSON mode failed, falling back to none mode: #{e.message}")
        organize_categories_with_mode(Provider::Openai::AutoCategorizer::JSON_MODE_NONE)
      else
        raise
      end
    end

    def organize_categories_with_mode(mode)
      span = langfuse_trace&.span(name: "organize_categories_api_call", input: {
        model: effective_model,
        categories: categories,
        json_mode: mode
      })

      params = {
        model: effective_model,
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
            name: "organize_personal_finance_categories",
            strict: true,
            schema: json_schema
          }
        }
      when Provider::Openai::AutoCategorizer::JSON_MODE_OBJECT
        params[:response_format] = { type: "json_object" }
      end

      response = client.chat(parameters: params)
      result = build_response(extract_suggestions_generic(response))
      record_usage(
        effective_model,
        response.dig("usage"),
        operation: "organize_categories",
        metadata: { category_count: categories.size, json_mode: mode }
      )
      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def build_response(suggestions)
      Array(suggestions).map do |suggestion|
        CleanupSuggestion.new(
          action: suggestion["action"],
          source_category_id: suggestion["source_category_id"],
          target_category_id: suggestion["target_category_id"],
          new_name: suggestion["new_name"],
          parent_category_id: suggestion["parent_category_id"],
          rationale: suggestion["rationale"],
          confidence: suggestion["confidence"]
        )
      end
    end

    def extract_suggestions_native(response)
      message_output = response["output"]&.find { |o| o["type"] == "message" }
      raw = message_output&.dig("content", 0, "text")

      raise Provider::Openai::Error, "No message content found in response" if raw.nil?

      JSON.parse(raw).dig("suggestions")
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in category cleanup suggestions: #{e.message}"
    end

    def extract_suggestions_generic(response)
      raw = response.dig("choices", 0, "message", "content")
      parsed = parse_json_flexibly(raw)
      suggestions = if parsed.is_a?(Array)
        parsed
      elsif parsed.is_a?(Hash)
        parsed["suggestions"] || parsed["category_suggestions"]
      end

      raise Provider::Openai::Error, "Could not find category cleanup suggestions in response" if suggestions.nil?

      suggestions.map do |suggestion|
        {
          "action" => suggestion["action"] || suggestion["suggested_action"],
          "source_category_id" => suggestion["source_category_id"] || suggestion["source_id"],
          "target_category_id" => suggestion["target_category_id"] || suggestion["target_id"],
          "new_name" => suggestion["new_name"] || suggestion["name"],
          "parent_category_id" => suggestion["parent_category_id"] || suggestion["new_parent_category_id"] || suggestion["parent_id"],
          "rationale" => suggestion["rationale"] || suggestion["reason"],
          "confidence" => suggestion["confidence"]
        }
      end
    end

    def parse_json_flexibly(raw)
      return {} if raw.blank?

      cleaned = raw.to_s.gsub(/<think>[\s\S]*?<\/think>/m, "").strip
      JSON.parse(cleaned)
    rescue JSON::ParserError
      if cleaned =~ /```(?:json)?\s*([\s\S]*?)\s*```/m
        return JSON.parse($1)
      end

      json_fragment = first_json_fragment(cleaned)
      if json_fragment.present?
        return JSON.parse(json_fragment)
      end

      raise Provider::Openai::Error, "Could not parse JSON from response"
    end

    def first_json_fragment(text)
      [ text.match(/(\{[\s\S]*\})/m), text.match(/(\[[\s\S]*\])/m) ]
        .compact
        .min_by { |match| match.begin(1) }&.[](1)
    end

    def json_schema
      category_ids = categories.map { |category| category["id"].to_s }

      {
        type: "object",
        properties: {
          suggestions: {
            type: "array",
            description: "Category cleanup suggestions for a personal finance category tree",
            items: {
              type: "object",
              properties: {
                action: { type: "string", enum: %w[merge rename reparent keep] },
                source_category_id: { type: "string", enum: category_ids },
                target_category_id: { type: [ "string", "null" ], enum: category_ids + [ nil ] },
                new_name: { type: [ "string", "null" ] },
                parent_category_id: { type: [ "string", "null" ], enum: category_ids + [ nil ] },
                rationale: { type: "string" },
                confidence: { type: "number" }
              },
              required: [ "action", "source_category_id", "target_category_id", "new_name", "parent_category_id", "rationale", "confidence" ],
              additionalProperties: false
            }
          }
        },
        required: [ "suggestions" ],
        additionalProperties: false
      }
    end

    def instructions
      <<~INSTRUCTIONS.strip_heredoc
        You are organizing categories in a personal finance app.
        Review the existing category tree and propose cleanup actions for duplicate, overlapping, vague, or misplaced categories.

        Rules:
        - Return JSON only.
        - Suggest only changes that are worth a user's review.
        - Use existing category IDs exactly as provided.
        - Supported actions are merge, rename, reparent, and keep.
        - For merge, source_category_id is removed and its transactions move to target_category_id.
        - For rename, provide new_name and leave target_category_id and parent_category_id null.
        - For reparent, parent_category_id is either a root category ID or null to make the source a root category.
        - For keep, all destination fields must be null.
        - Do not create new categories in this cleanup pass.
        - Do not suggest deleting a category unless it is merged into another category.
        - Respect the app's two-level nesting limit: root categories can have child categories, but child categories cannot have children.
        - Do not suggest merging a parent category into one of its children.
        - Prefer fewer high-confidence suggestions over many speculative ones.
      INSTRUCTIONS
    end

    def developer_message
      <<~MESSAGE.strip_heredoc
        Existing categories:

        ```json
        #{categories.to_json}
        ```
      MESSAGE
    end

    def developer_message_for_generic
      <<~MESSAGE.strip_heredoc
        EXISTING CATEGORIES:
        #{categories.to_json}

        Respond with ONLY JSON:
        {"suggestions":[{"action":"merge","source_category_id":"source-category-id","target_category_id":"target-category-id","new_name":null,"parent_category_id":null,"rationale":"Duplicate category names overlap strongly","confidence":0.9}]}
      MESSAGE
    end

    def effective_model
      model.presence || Provider::Openai::DEFAULT_MODEL
    end
end
