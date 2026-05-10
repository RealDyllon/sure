class CreateFinancialGoals < ActiveRecord::Migration[7.2]
  def change
    create_table :financial_goals, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :goal_type, null: false, default: "custom"
      t.string :name
      t.decimal :target_amount, precision: 19, scale: 4
      t.string :target_currency, null: false
      t.date :target_date
      t.string :status, null: false, default: "active"
      t.integer :position, null: false, default: 0
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :financial_goals, [ :family_id, :user_id, :status ]
    add_index :financial_goals, [ :family_id, :user_id, :position ]
  end
end
