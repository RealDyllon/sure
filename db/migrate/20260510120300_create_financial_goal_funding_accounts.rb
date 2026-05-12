class CreateFinancialGoalFundingAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :financial_goal_funding_accounts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :financial_goal, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :account, null: true, foreign_key: { on_delete: :nullify }, type: :uuid

      t.timestamps
    end

    add_index :financial_goal_funding_accounts,
      [ :financial_goal_id, :account_id ],
      unique: true,
      where: "account_id IS NOT NULL",
      name: "index_goal_funding_accounts_unique_account"
  end
end
