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
      @seen_renames = {}
    end

    def call
      suggestions.filter_map do |suggestion|
        attrs = attrs_for(suggestion)
        next if attrs[:source_category].blank?

        key = suggestion_key(attrs)
        next if seen_keys.include?(key)

        seen_keys << key
        attrs = apply_rename_conflict(attrs)
        attrs
      end
    end

    private
      attr_reader :suggestions, :run, :categories_by_id, :seen_keys
      attr_accessor :seen_renames

      def attrs_for(suggestion)
        raw = suggestion.respond_to?(:to_h) ? suggestion.to_h : suggestion
        raw = raw.deep_symbolize_keys

        action = ACTIONS.include?(raw[:action].to_s) ? raw[:action].to_s : "keep"
        source_category = categories_by_id[raw[:source_category_id].to_s]
        target_category = categories_by_id[raw[:target_category_id].to_s]
        parent_category = categories_by_id[raw[:parent_category_id].to_s]
        confidence = normalized_confidence(raw[:confidence])

        reparent_intended_root = action == "reparent" && raw[:parent_category_id].blank?
        reparent_intended_parent_id = action == "reparent" ? raw[:parent_category_id].to_s.presence : nil

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
          metadata: {
            "provider_suggestion" => raw.compact,
            "reparent_intended_root" => reparent_intended_root,
            "reparent_intended_parent_category_id" => reparent_intended_parent_id
          }
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
          return "parent category missing" if parent.blank? && attrs.dig(:metadata, "reparent_intended_parent_category_id").present?
          return nil if parent.blank?
          return "parent category outside family" if parent.family_id != run.family_id
          return "cannot parent a category to itself" if parent.id == source.id
          return "cannot parent under a subcategory" if parent.subcategory?
          return "cannot move a parent category under another parent" if source.subcategories.exists?
        end

        nil
      end

      def normalized_confidence(value)
        return 0.0 if value.blank?

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

      # When the provider returns two or more rename suggestions for the same
      # source category with different `new_name` values, only the first such
      # suggestion in normalization order keeps the default selection. Any
      # later rename with a different new_name is flagged for review so the
      # user picks one explicitly instead of having both apply in sequence.
      def apply_rename_conflict(attrs)
        return attrs unless attrs[:suggested_action] == "rename"

        source_id = attrs[:source_category].id
        first_new_name = seen_renames[source_id]

        if first_new_name && first_new_name != attrs[:new_name]
          attrs.merge(
            selected: false,
            status: "needs_review",
            error: "conflicting rename suggestion for this category"
          )
        else
          seen_renames[source_id] = attrs[:new_name]
          attrs
        end
      end
  end
end
