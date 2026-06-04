require "set"

module CategoryCleanup
  class SuggestionNormalizer
    ACTIONS = %w[keep merge rename reparent].freeze
    MIN_CONFIDENCE_FOR_DEFAULT_SELECTION = 0.6

    def self.call(suggestions:, run:)
      new(suggestions: suggestions, run: run).call
    end

    def initialize(suggestions:, run:)
      @suggestions = Array(suggestions)
      @run = run
      @categories_by_id = run.family.categories.index_by { |category| category.id.to_s }
      @seen_keys = Set.new
    end

    def call
      suggestions.filter_map do |suggestion|
        attrs = attrs_for(suggestion)
        next if attrs[:source_category].blank?

        key = suggestion_key(attrs)
        next if seen_keys.include?(key)

        seen_keys << key
        attrs
      end
    end

    private
      attr_reader :suggestions, :run, :categories_by_id, :seen_keys

      def attrs_for(suggestion)
        raw = suggestion.respond_to?(:to_h) ? suggestion.to_h : suggestion
        raw = raw.deep_symbolize_keys

        action = ACTIONS.include?(raw[:action].to_s) ? raw[:action].to_s : "keep"
        source_category = categories_by_id[raw[:source_category_id].to_s]
        target_category = categories_by_id[raw[:target_category_id].to_s]
        parent_category = categories_by_id[raw[:parent_category_id].to_s]
        confidence = normalized_confidence(raw[:confidence])

        attrs = {
          source_category: source_category,
          target_category: target_category,
          parent_category: parent_category,
          suggested_action: action,
          source_category_name: source_category&.name || raw[:source_category_name],
          target_category_name: target_category&.name || raw[:target_category_name],
          parent_category_name: parent_category&.name || raw[:parent_category_name],
          new_name: raw[:new_name].to_s.squish.presence,
          rationale: raw[:rationale].to_s.squish.presence,
          confidence: confidence,
          metadata: { "provider_suggestion" => raw.compact }
        }

        review_error = review_error_for(attrs)
        attrs.merge(
          selected: review_error.blank? && action != "keep" && confidence >= MIN_CONFIDENCE_FOR_DEFAULT_SELECTION,
          status: review_error.present? ? "needs_review" : "suggested",
          error: review_error
        )
      end

      def review_error_for(attrs)
        source = attrs[:source_category]
        target = attrs[:target_category]
        parent = attrs[:parent_category]

        return "source category deleted" if source.blank?
        return "source category outside family" if source.family_id != run.family_id
        return nil if attrs[:suggested_action] == "keep"

        case attrs[:suggested_action]
        when "merge"
          return "target category missing" if target.blank?
          return "target category outside family" if target.family_id != run.family_id
          return "source and target are the same category" if source.id == target.id
          return "cannot merge a category into its own child" if target.parent_id == source.id
          return "cannot merge a parent category into a subcategory" if source.subcategories.exists? && target.subcategory?
        when "rename"
          new_name = attrs[:new_name].to_s.squish
          return "new name missing" if new_name.blank?
          return "category name already exists" if new_name != source.name && run.family.categories.where.not(id: source.id).exists?(name: new_name)
        when "reparent"
          return nil if parent.blank?
          return "parent category outside family" if parent.family_id != run.family_id
          return "cannot parent a category to itself" if parent.id == source.id
          return "cannot parent under a subcategory" if parent.subcategory?
          return "cannot move a parent category under another parent" if source.subcategories.exists?
        end

        nil
      end

      def normalized_confidence(value)
        number = value.to_f
        return 0.0 if number.nan? || number.infinite?

        number.clamp(0.0, 1.0)
      end

      def suggestion_key(attrs)
        [
          attrs[:suggested_action],
          attrs[:source_category]&.id,
          attrs[:target_category]&.id,
          attrs[:parent_category]&.id,
          attrs[:new_name].to_s.downcase
        ].join(":")
      end
  end
end
