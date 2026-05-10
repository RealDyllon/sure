class CreateAutoCategorizationWizardTables < ActiveRecord::Migration[7.2]
  def change
    create_table :auto_categorization_runs, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :status, null: false, default: "draft"
      t.string :provider_name
      t.string :model
      t.integer :category_suggestions_count, null: false, default: 0
      t.integer :transaction_suggestions_count, null: false, default: 0
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

      t.index [ :family_id, :status ]
      t.index [ :user_id, :status ]
      t.index [ :created_at ]
    end

    create_table :auto_categorization_run_transactions, id: :uuid do |t|
      t.references :auto_categorization_run, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: { name: "idx_auto_cat_run_txns_on_run_id" }
      t.references :entry, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :transaction, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :account, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :status, null: false, default: "pending_generation"
      t.jsonb :snapshot, null: false, default: {}
      t.datetime :captured_at, null: false
      t.timestamps

      t.index [ :auto_categorization_run_id, :status ], name: "idx_auto_cat_run_txns_on_run_status"
      t.index [ :auto_categorization_run_id, :transaction_id ], name: "idx_auto_cat_run_txns_on_run_txn"
    end

    create_table :auto_categorization_category_suggestions, id: :uuid do |t|
      t.references :auto_categorization_run, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: { name: "idx_auto_cat_cat_suggestions_on_run_id" }
      t.string :name, null: false
      t.string :normalized_name, null: false
      t.string :parent_name
      t.string :color, null: false
      t.string :lucide_icon, null: false
      t.text :rationale
      t.boolean :selected, null: false, default: true
      t.references :created_category, null: true, foreign_key: { to_table: :categories, on_delete: :nullify }, type: :uuid, index: { name: "idx_auto_cat_cat_suggestions_on_created_category" }
      t.string :status, null: false, default: "suggested"
      t.text :error
      t.timestamps

      t.index [ :auto_categorization_run_id, :status ], name: "idx_auto_cat_cat_suggestions_on_run_status"
      t.index [ :auto_categorization_run_id, :selected ], name: "idx_auto_cat_cat_suggestions_on_run_selected"
      t.index [ :auto_categorization_run_id, :normalized_name ], name: "idx_auto_cat_cat_suggestions_on_run_name"
    end

    create_table :auto_categorization_suggestions, id: :uuid do |t|
      t.references :auto_categorization_run, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: { name: "idx_auto_cat_suggestions_on_run_id" }
      t.references :auto_categorization_run_transaction, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: { name: "idx_auto_cat_suggestions_on_run_transaction" }
      t.references :suggested_category, null: true, foreign_key: { to_table: :categories, on_delete: :nullify }, type: :uuid, index: { name: "idx_auto_cat_suggestions_on_suggested_category" }
      t.references :selected_category, null: true, foreign_key: { to_table: :categories, on_delete: :nullify }, type: :uuid, index: { name: "idx_auto_cat_suggestions_on_selected_category" }
      t.string :suggested_category_name
      t.string :selected_category_name
      t.boolean :selected, null: false, default: false
      t.string :status, null: false, default: "pending_generation"
      t.text :reason
      t.text :error
      t.datetime :applied_at
      t.timestamps

      t.index [ :auto_categorization_run_id, :status ], name: "idx_auto_cat_suggestions_on_run_status"
      t.index [ :auto_categorization_run_id, :selected ], name: "idx_auto_cat_suggestions_on_run_selected"
      t.index [ :auto_categorization_run_id, :auto_categorization_run_transaction_id ], unique: true, name: "idx_auto_cat_suggestions_unique_run_transaction"
    end
  end
end
