class CreateStatementProfilesAndImportFields < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :statement_pdf_password, :text

    create_table :statement_profiles, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :provider, null: false
      t.string :source_id, null: false
      t.string :source_name
      t.string :account_type, null: false
      t.string :account_subtype
      t.string :currency, null: false
      t.date :last_statement_end_on
      t.jsonb :metadata, default: {}, null: false
      t.timestamps

      t.index [ :family_id, :provider, :source_id ], unique: true, name: "idx_statement_profiles_unique_source"
    end
  end
end
