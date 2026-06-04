class CreateCategoryCleanupWizardTables < ActiveRecord::Migration[7.2]
  def change
    create_table :category_cleanup_runs, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :status, null: false, default: "draft"
      t.string :provider_name
      t.string :model
      t.integer :suggestions_count, null: false, default: 0
      t.integer :selected_count, null: false, default: 0
      t.integer :applied_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.integer :unchanged_count, null: false, default: 0
      t.text :error
      t.jsonb :processing_progress, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :category_cleanup_runs, [ :user_id, :status, :created_at ]

    create_table :category_cleanup_suggestions, id: :uuid do |t|
      t.references :category_cleanup_run, null: false, foreign_key: true, type: :uuid, index: { name: "idx_category_cleanup_suggestions_on_run_id" }
      t.references :source_category, foreign_key: { to_table: :categories, on_delete: :nullify }, type: :uuid
      t.references :target_category, foreign_key: { to_table: :categories, on_delete: :nullify }, type: :uuid
      t.references :parent_category, foreign_key: { to_table: :categories, on_delete: :nullify }, type: :uuid
      t.string :suggested_action, null: false, default: "keep"
      t.string :source_category_name
      t.string :target_category_name
      t.string :parent_category_name
      t.string :new_name
      t.decimal :confidence, precision: 5, scale: 4
      t.text :rationale
      t.boolean :selected, null: false, default: false
      t.string :status, null: false, default: "suggested"
      t.text :error
      t.jsonb :metadata, null: false, default: {}
      t.datetime :applied_at

      t.timestamps
    end

    add_index :category_cleanup_suggestions, [ :category_cleanup_run_id, :selected ], name: "idx_category_cleanup_suggestions_on_run_selected"
    add_index :category_cleanup_suggestions, [ :category_cleanup_run_id, :status ], name: "idx_category_cleanup_suggestions_on_run_status"
    add_index :category_cleanup_suggestions, [ :category_cleanup_run_id, :suggested_action ], name: "idx_category_cleanup_suggestions_on_run_action"
  end
end
