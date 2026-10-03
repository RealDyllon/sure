class CreateFireProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :fire_profiles, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.string :planning_region, null: false, default: "generic"
      t.integer :current_age
      t.decimal :annual_spending_override, precision: 19, scale: 4
      t.decimal :annual_contribution, precision: 19, scale: 4, null: false, default: 0
      t.decimal :withdrawal_rate, precision: 8, scale: 5, null: false, default: 0.04
      t.decimal :expected_return, precision: 8, scale: 5, null: false, default: 0.06
      t.decimal :inflation_rate, precision: 8, scale: 5, null: false, default: 0.02
      t.integer :cpf_access_age, null: false, default: 55
      t.integer :cpf_life_age, null: false, default: 65
      t.integer :srs_access_age, null: false, default: 63
      t.jsonb :account_role_overrides, null: false, default: {}
      t.timestamps
    end
    add_index :fire_profiles, [ :user_id, :family_id ], unique: true
  end
end
