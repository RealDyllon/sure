class AutoCategorizationCategorySuggestion < ApplicationRecord
  self.table_name = "auto_categorization_category_suggestions"

  belongs_to :run,
             class_name: "AutoCategorizationRun",
             foreign_key: :auto_categorization_run_id,
             inverse_of: :category_suggestions
  belongs_to :created_category, class_name: "Category", optional: true

  enum :status, {
    suggested: "suggested",
    invalid: "invalid",
    created: "created",
    matched_existing: "matched_existing",
    skipped: "skipped",
    failed: "failed"
  }, validate: true, default: "suggested", prefix: true

  scope :selected, -> { where(selected: true) }
  scope :valid_for_creation, -> { where(status: %w[suggested matched_existing]) }

  before_validation :normalize_attributes

  validates :name, :normalized_name, :color, :lucide_icon, presence: true
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }

  def create_category!
    return created_category if created_category.present?

    unless selected? && name.present?
      update!(status: :skipped)
      return nil
    end

    category = find_existing_category(normalized_name)
    if category
      update!(created_category: category, status: :matched_existing, error: nil)
      return category
    end

    parent = find_or_create_parent

    category = run.family.categories.create!(
      name: name,
      parent: parent,
      color: color,
      lucide_icon: lucide_icon
    )

    update!(created_category: category, status: :created, error: nil)
    category
  rescue => error
    update!(status: :failed, error: AutoCategorization::ErrorSanitizer.call(error))
    raise
  end

  private
    def normalize_attributes
      self.name = name.to_s.squish
      self.parent_name = parent_name.to_s.squish.presence
      self.normalized_name = self.class.normalize_name(name)
      self.parent_name = nil if self.class.normalize_name(parent_name) == normalized_name
      self.color = valid_color?(color) ? color : Category::COLORS.sample
      self.lucide_icon = Category.icon_codes.include?(lucide_icon.to_s) ? lucide_icon : Category.suggested_icon(name)
      self.status = "invalid" if name.blank?
    end

    def find_existing_category(normalized)
      run.family.categories.find { |category| self.class.normalize_name(category.name) == normalized }
    end

    def find_or_create_parent
      return nil if parent_name.blank?

      normalized_parent = self.class.normalize_name(parent_name)
      existing = find_existing_category(normalized_parent)
      return existing if existing

      run.family.categories.create!(
        name: parent_name,
        color: color,
        lucide_icon: Category.suggested_icon(parent_name)
      )
    end

    def valid_color?(value)
      value.to_s.match?(/\A#[0-9A-Fa-f]{6}\z/)
    end

    class << self
      def normalize_name(value)
        value.to_s.squish.downcase
      end
    end
end
