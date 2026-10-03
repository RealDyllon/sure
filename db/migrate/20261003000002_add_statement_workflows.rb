class AddStatementWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_reference :imports, :initiating_user, type: :uuid, foreign_key: { to_table: :users }
    add_column :imports, :statement_pdf_password, :text
    add_column :imports, :processing_progress, :jsonb, null: false, default: {}
    add_column :imports, :publication_journal, :jsonb, null: false, default: {}
    create_table :statement_profiles, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :source_id, null: false
      t.string :source_name
      t.string :account_type, null: false
      t.string :account_subtype
      t.string :currency, null: false
      t.date :last_statement_end_on
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :statement_profiles, [ :family_id, :provider, :source_id ], unique: true
    create_table :statement_import_accounts, id: :uuid do |t|
      t.references :statement_import, type: :uuid, null: false, foreign_key: { to_table: :imports }
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.string :source_id, null: false
      t.timestamps
    end
    add_index :statement_import_accounts, [ :statement_import_id, :source_id ], unique: true
  end
end
