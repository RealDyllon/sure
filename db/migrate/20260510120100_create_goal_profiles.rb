class CreateGoalProfiles < ActiveRecord::Migration[7.2]
  def change
    create_table :goal_profiles, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :planning_region
      t.integer :current_age
      t.integer :birth_year
      t.decimal :annual_spending_override, precision: 19, scale: 4
      t.decimal :withdrawal_rate, precision: 10, scale: 6, default: 0.04, null: false
      t.decimal :expected_return, precision: 10, scale: 6, default: 0.05, null: false
      t.decimal :inflation_rate, precision: 10, scale: 6, default: 0.02, null: false
      t.decimal :savings_rate_target, precision: 10, scale: 6
      t.integer :emergency_fund_months, default: 6, null: false
      t.integer :cpf_access_age, default: 55, null: false
      t.integer :cpf_life_age, default: 65, null: false
      t.integer :srs_access_age, default: 63, null: false
      t.jsonb :skipped_prompts, default: [], null: false
      t.jsonb :account_role_overrides, default: {}, null: false

      t.timestamps
    end

    add_index :goal_profiles, [ :family_id, :user_id ], unique: true
  end
end
