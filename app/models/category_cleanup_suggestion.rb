class CategoryCleanupSuggestion < ApplicationRecord
  self.table_name = "category_cleanup_suggestions"

  belongs_to :run,
             class_name: "CategoryCleanupRun",
             foreign_key: :category_cleanup_run_id,
             inverse_of: :suggestions
  belongs_to :source_category, class_name: "Category", optional: true
  belongs_to :target_category, class_name: "Category", optional: true
  belongs_to :parent_category, class_name: "Category", optional: true

  enum :suggested_action, {
    keep: "keep",
    merge: "merge",
    rename: "rename",
    reparent: "reparent"
  }, validate: true, default: "keep", prefix: :action

  enum :status, {
    suggested: "suggested",
    needs_review: "needs_review",
    applied: "applied",
    skipped: "skipped",
    unchanged: "unchanged",
    failed: "failed"
  }, validate: true, default: "suggested"

  scope :selected, -> { where(selected: true) }
  scope :actionable, -> { where.not(suggested_action: "keep") }

  before_validation :sync_snapshot_names

  def apply!
    return false if applied_at.present?
    return mark_unchanged! if action_keep?
    return skip!("source category deleted") if source_category.blank?
    return skip!("source category outside family") if source_category.family_id != run.family_id

    case suggested_action
    when "merge"
      apply_merge!
    when "rename"
      apply_rename!
    when "reparent"
      apply_reparent!
    else
      skip!("unsupported action")
    end
  rescue => error
    update!(status: :skipped, error: AutoCategorization::ErrorSanitizer.call(error))
    false
  end

  def review_error
    validation_error.presence || error
  end

  def current_review_error
    validation_error
  end

  def valid_for_selection?
    validation_error.blank? && !action_keep?
  end

  private
    def apply_merge!
      return skip!("target category missing") if target_category.blank?
      return skip!("target category outside family") if target_category.family_id != run.family_id
      return skip!("source and target are the same category") if source_category.id == target_category.id
      return skip!("cannot merge a category into its own child") if target_category.parent_id == source_category.id
      return skip!("cannot merge a parent category into a subcategory") if source_category.subcategories.exists? && target_category.subcategory?

      Category.transaction do
        now = Time.current
        source_category.transactions.update_all(category_id: target_category.id, updated_at: now)
        source_category.subcategories.update_all(parent_id: target_category.id, updated_at: now) if target_category.parent_id.nil?
        reassign_budget_categories!(now: now)
        source_category.destroy!
      end

      mark_applied!
    end

    def reassign_budget_categories!(now:)
      source_category.budget_categories.lock.find_each do |source_budget_category|
        target_budget_category = BudgetCategory.lock.find_by(
          budget_id: source_budget_category.budget_id,
          category_id: target_category.id
        )

        if target_budget_category
          target_budget_category.update!(
            budgeted_spending: target_budget_category.budgeted_spending + source_budget_category.budgeted_spending,
            updated_at: now
          )
          source_budget_category.destroy!
        else
          source_budget_category.update!(category: target_category, updated_at: now)
        end
      end
    end

    def apply_rename!
      cleaned_name = new_name.to_s.squish
      return skip!("new name missing") if cleaned_name.blank?
      return mark_unchanged! if cleaned_name == source_category.name
      return skip!("category name already exists") if duplicate_name?(cleaned_name)

      source_category.update!(name: cleaned_name)
      mark_applied!
    end

    def apply_reparent!
      return skip!("parent category outside family") if parent_category.present? && parent_category.family_id != run.family_id
      return skip!("cannot parent a category to itself") if parent_category&.id == source_category.id
      return skip!("cannot parent under a subcategory") if parent_category&.subcategory?
      return skip!("cannot move a parent category under another parent") if parent_category.present? && source_category.subcategories.exists?
      return mark_unchanged! if source_category.parent_id == parent_category&.id

      source_category.update!(parent: parent_category)
      mark_applied!
    end

    def validation_error
      return "source category deleted" if source_category.blank?
      return "source category outside family" if source_category.family_id != run.family_id
      return nil if action_keep?

      case suggested_action
      when "merge"
        merge_validation_error
      when "rename"
        rename_validation_error
      when "reparent"
        reparent_validation_error
      else
        "unsupported action"
      end
    end

    def merge_validation_error
      return "target category missing" if target_category.blank?
      return "target category outside family" if target_category.family_id != run.family_id
      return "source and target are the same category" if source_category.id == target_category.id
      return "cannot merge a category into its own child" if target_category.parent_id == source_category.id
      return "cannot merge a parent category into a subcategory" if source_category.subcategories.exists? && target_category.subcategory?

      nil
    end

    def rename_validation_error
      cleaned_name = new_name.to_s.squish
      return "new name missing" if cleaned_name.blank?
      return "category name already exists" if cleaned_name != source_category.name && duplicate_name?(cleaned_name)

      nil
    end

    def reparent_validation_error
      return "parent category outside family" if parent_category.present? && parent_category.family_id != run.family_id
      return "cannot parent a category to itself" if parent_category&.id == source_category.id
      return "cannot parent under a subcategory" if parent_category&.subcategory?
      return "cannot move a parent category under another parent" if parent_category.present? && source_category.subcategories.exists?

      nil
    end

    def duplicate_name?(name)
      run.family.categories.where.not(id: source_category.id).exists?(name: name)
    end

    def mark_applied!
      update!(status: :applied, applied_at: Time.current, error: nil)
      true
    end

    def mark_unchanged!
      update!(status: :unchanged, applied_at: Time.current, error: nil)
      false
    end

    def skip!(reason)
      update!(status: :skipped, error: reason)
      false
    end

    def sync_snapshot_names
      self.source_category_name = source_category.name if source_category.present?
      self.target_category_name = target_category.name if target_category.present?
      self.parent_category_name = parent_category.name if parent_category.present?
    end
end
