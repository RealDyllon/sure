require "set"

module AutoCategorization
  class StarterCategoryNormalizer
    def self.call(categories:, family:)
      new(categories:, family:).call
    end

    def initialize(categories:, family:)
      @categories = Array(categories)
      @family = family
      @seen_names = Set.new(existing_names)
    end

    def call
      categories.filter_map do |category|
        attrs = attrs_for(category)
        next if attrs[:name].blank?

        normalized = AutoCategorizationCategorySuggestion.normalize_name(attrs[:name])
        next if seen_names.include?(normalized)

        seen_names << normalized
        attrs.merge(
          normalized_name: normalized,
          selected: true,
          status: "suggested"
        )
      end
    end

    private
      attr_reader :categories, :family, :seen_names

      def existing_names
        family.categories.map { |category| AutoCategorizationCategorySuggestion.normalize_name(category.name) }
      end

      def attrs_for(category)
        raw = category.respond_to?(:to_h) ? category.to_h : category
        raw = raw.deep_symbolize_keys

        name = raw[:name].to_s.squish
        parent_name = raw[:parent_name].to_s.squish.presence
        parent_name = nil if AutoCategorizationCategorySuggestion.normalize_name(parent_name) == AutoCategorizationCategorySuggestion.normalize_name(name)

        {
          name: name,
          parent_name: parent_name,
          color: valid_color?(raw[:color]) ? raw[:color] : Category::COLORS.sample,
          lucide_icon: valid_icon?(raw[:lucide_icon]) ? raw[:lucide_icon] : Category.suggested_icon(name),
          rationale: raw[:rationale].to_s.squish.presence
        }
      end

      def valid_color?(value)
        value.to_s.match?(/\A#[0-9A-Fa-f]{6}\z/)
      end

      def valid_icon?(value)
        Category.icon_codes.include?(value.to_s)
      end
  end
end
