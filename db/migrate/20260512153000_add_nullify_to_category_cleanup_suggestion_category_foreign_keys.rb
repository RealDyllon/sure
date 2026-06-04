class AddNullifyToCategoryCleanupSuggestionCategoryForeignKeys < ActiveRecord::Migration[7.2]
  def change
    remove_foreign_key :category_cleanup_suggestions, column: :source_category_id
    remove_foreign_key :category_cleanup_suggestions, column: :target_category_id
    remove_foreign_key :category_cleanup_suggestions, column: :parent_category_id

    add_foreign_key :category_cleanup_suggestions, :categories, column: :source_category_id, on_delete: :nullify
    add_foreign_key :category_cleanup_suggestions, :categories, column: :target_category_id, on_delete: :nullify
    add_foreign_key :category_cleanup_suggestions, :categories, column: :parent_category_id, on_delete: :nullify
  end
end
