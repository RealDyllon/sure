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
    Rails.logger.error("CategoryCleanupSuggestion(#{id}) apply failed: #{error.class}: #{error.message}\n#{error.backtrace&.first(10)&.join("\n")}")
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
        reassigned_transaction_ids = source_category.transactions.pluck(:id)
        source_category.transactions.update_all(category_id: target_category.id, updated_at: now)
        # Bump the corresponding entries' updated_at so the family entries_cache_version
        # (entries.maximum(:updated_at)) is invalidated. The bulk update_all above
        # bypasses the Entryable `touch: true` callback on the Transaction -> Entry
        # association, leaving report caches keyed to the old category_id.
        Entry.where(entryable_type: "Transaction", entryable_id: reassigned_transaction_ids).update_all(updated_at: now) if reassigned_transaction_ids.any?
        source_category.subcategories.update_all(parent_id: target_category.id, color: target_category.color, updated_at: now) if target_category.parent_id.nil?
        reassign_budget_categories!(now: now)
        repoint_rule_categories!(source_category: source_category, target_category: target_category)
        reassign_import_mappings!(source_category: source_category, target_category: target_category)
        source_category.destroy!
        mark_applied!
      end
    end

    def reassign_budget_categories!(now:)
      source_category.budget_categories.lock.find_each do |source_budget_category|
        source_amount = source_budget_category.budgeted_spending || 0

        # Detach source amount from its old parent first so parent budgets don't double-count
        # when a subcategory is merged elsewhere.
        if source_budget_category.subcategory? && source_amount.nonzero?
          source_budget_category.update_budgeted_spending!(0)
        end

        target_budget_category = BudgetCategory.lock.find_by(
          budget_id: source_budget_category.budget_id,
          category_id: target_category.id
        )

        if target_budget_category
          merge_into_existing_budget_category!(source_budget_category, target_budget_category, source_amount:, now:)
        else
          move_budget_category_to_target!(source_budget_category, source_amount, now)
        end
      end
    end

    def merge_into_existing_budget_category!(source_budget_category, target_budget_category, source_amount:, now:)
      target_amount = (target_budget_category.budgeted_spending || 0) + source_amount

      if target_budget_category.subcategory?
        target_budget_category.update_budgeted_spending!(target_amount)
      else
        target_budget_category.update!(budgeted_spending: target_amount, updated_at: now)
      end

      source_budget_category.destroy!
    end

    def move_budget_category_to_target!(source_budget_category, source_amount, now)
      target_is_subcategory = target_category.subcategory?

      # Zero the row before re-pointing the category. For a subcategory source this
      # detaches the amount from the old parent; for a root source it just resets
      # the value so the subsequent update_budgeted_spending! call below sees a
      # real delta and correctly increments the new (target) parent budget.
      # Without this, sync_parent_budgeted_spending! would see previous == new and
      # leave the target parent budget understated by source_amount.
      if target_is_subcategory && source_amount.nonzero?
        source_budget_category.update_budgeted_spending!(0)
      end

      source_budget_category.update!(category: target_category, updated_at: now)

      if target_is_subcategory
        source_budget_category.update_budgeted_spending!(source_amount) if source_amount.nonzero?
      elsif source_amount.nonzero?
        source_budget_category.update!(budgeted_spending: source_amount, updated_at: now)
      end
    end

    def apply_rename!
      cleaned_name = new_name.to_s.squish
      return skip!("new name missing") if cleaned_name.blank?
      return mark_unchanged! if cleaned_name == source_category.name
      return skip!("category name already exists") if duplicate_name?(cleaned_name)

      Category.transaction do
        source_category.update!(name: cleaned_name)
        mark_applied!
      end
    end

    def apply_reparent!
      return skip!("parent category outside family") if parent_category.present? && parent_category.family_id != run.family_id
      return skip!("cannot parent a category to itself") if parent_category&.id == source_category.id
      return skip!("cannot parent under a subcategory") if parent_category&.subcategory?
      return skip!("cannot move a parent category under another parent") if parent_category.present? && source_category.subcategories.exists?
      return skip!("parent category missing") if parent_category.blank? && intended_parent_category_id_for_reparent.present?
      return mark_unchanged! if source_category.parent_id == parent_category&.id

      Category.transaction do
        reparent_budget_snapshots = snapshot_reparent_budgets!
        source_category.update!(parent: parent_category)
        restore_reparent_budgets!(reparent_budget_snapshots)
        mark_applied!
      end
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
      return "parent category missing" if parent_category.blank? && intended_parent_category_id_for_reparent.present?

      nil
    end

    def duplicate_name?(name)
      run.family.categories.where.not(id: source_category.id).exists?(name: name)
    end

    def intended_parent_category_id_for_reparent
      return nil unless action_reparent?

      metadata.to_h["reparent_intended_parent_category_id"].presence
    end

    def snapshot_reparent_budgets!
      source_category.budget_categories.lock.map do |budget_category|
        amount = budget_category.budgeted_spending || 0
        was_subcategory = budget_category.subcategory?

        budget_category.update_budgeted_spending!(0) if amount.nonzero?

        {
          budget_category: budget_category,
          amount: amount,
          was_subcategory: was_subcategory
        }
      end
    end

    def restore_reparent_budgets!(snapshots)
      snapshots.each do |snapshot|
        budget_category = snapshot[:budget_category]
        amount = snapshot[:amount]
        next if amount.zero?

        budget_category.reload

        if budget_category.subcategory?
          budget_category.update_budgeted_spending!(amount)
        else
          budget_category.update!(budgeted_spending: amount)
        end
      end
    end

    def repoint_rule_categories!(source_category:, target_category:)
      rule_ids = run.family.rule_ids

      Rule::Action.where(rule_id: rule_ids, action_type: "set_transaction_category", value: source_category.id)
                  .update_all(value: target_category.id)
      Rule::Condition.where(rule_id: rule_ids, condition_type: "transaction_category", value: source_category.id)
                     .update_all(value: target_category.id)

      # Compound rules store sub-conditions as Rule::Condition rows with
      # rule_id: nil and parent_id pointing at the compound parent. They
      # walk up to the parent rule via #rule, so a rule_id scope misses
      # them. Rewrite them in a second pass keyed by the family rule ids.
      compound_parent_ids = Rule::Condition.where(rule_id: rule_ids, condition_type: "compound").pluck(:id)
      if compound_parent_ids.any?
        Rule::Condition.where(parent_id: compound_parent_ids,
                              condition_type: "transaction_category",
                              value: source_category.id)
                       .update_all(value: target_category.id)
      end
    end

    def reassign_import_mappings!(source_category:, target_category:)
      Import::Mapping.where(mappable: source_category).find_each do |mapping|
        existing_target_mapping = Import::Mapping.find_by(
          import: mapping.import,
          type: mapping.type,
          key: mapping.key,
          mappable: target_category
        )

        if existing_target_mapping
          mapping.destroy!
        else
          mapping.update!(mappable: target_category)
        end
      end
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
      self.source_category_name = source_category&.name
      self.target_category_name = target_category&.name
      self.parent_category_name = parent_category&.name
    end
end
