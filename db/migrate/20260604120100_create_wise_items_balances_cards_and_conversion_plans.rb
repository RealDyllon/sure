class CreateWiseItemsBalancesCardsAndConversionPlans < ActiveRecord::Migration[7.2]
  def change
    create_table :wise_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :profile_id
      t.string :profile_type
      t.string :auth_mode, default: "oauth", null: false
      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false
      t.date :sync_start_date
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload
      t.text :access_token
      t.text :refresh_token
      t.text :personal_token
      t.datetime :token_expires_at
      t.string :base_url
      t.string :auth_url
      t.timestamps
    end

    add_index :wise_items, :status
    add_index :wise_items, :auth_mode

    create_table :wise_balances, id: :uuid do |t|
      t.references :wise_item, null: false, foreign_key: true, type: :uuid
      t.string :balance_id
      t.string :profile_id
      t.string :name
      t.string :currency
      t.string :balance_type
      t.string :account_status
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.boolean :skipped, default: false, null: false
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload, default: [], null: false
      t.jsonb :extra, default: {}, null: false
      t.timestamps
    end

    add_index :wise_balances, :balance_id
    add_index :wise_balances, [ :wise_item_id, :balance_id ],
      unique: true,
      where: "balance_id IS NOT NULL",
      name: "index_wise_balances_on_item_and_balance_id"

    create_table :wise_cards, id: :uuid do |t|
      t.references :wise_item, null: false, foreign_key: true, type: :uuid
      t.string :wise_card_id
      t.string :wise_balance_id
      t.string :profile_id
      t.string :name
      t.string :card_type
      t.string :status
      t.string :last_four
      t.integer :expiry_month
      t.integer :expiry_year
      t.string :currency
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload, default: [], null: false
      t.timestamps
    end

    add_index :wise_cards, [ :wise_item_id, :wise_card_id ],
      unique: true,
      where: "wise_card_id IS NOT NULL",
      name: "index_wise_cards_on_item_and_card_id"

    create_table :wise_conversion_intentions, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :source_account, foreign_key: { to_table: :accounts }, type: :uuid
      t.string :source_currency, null: false
      t.string :target_currency, null: false
      t.decimal :target_amount, precision: 19, scale: 4
      t.date :deadline_on
      t.date :trip_starts_on
      t.date :trip_ends_on
      t.decimal :desired_rate, precision: 19, scale: 8
      t.text :notes
      t.string :status, default: "active", null: false
      t.timestamps
    end

    add_index :wise_conversion_intentions, [ :family_id, :status ]

    create_table :wise_conversion_snapshots, id: :uuid do |t|
      t.references :wise_conversion_intention, null: false, foreign_key: true, type: :uuid
      t.decimal :quote_rate, precision: 19, scale: 8
      t.decimal :quote_fee_amount, precision: 19, scale: 4
      t.string :quote_fee_currency
      t.decimal :provider_rate, precision: 19, scale: 8
      t.string :provider_name
      t.decimal :rate_30d_percentile, precision: 6, scale: 2
      t.decimal :rate_90d_percentile, precision: 6, scale: 2
      t.decimal :rate_365d_percentile, precision: 6, scale: 2
      t.date :observed_on, null: false
      t.jsonb :raw_quote_payload
      t.timestamps
    end

    add_index :wise_conversion_snapshots, [ :wise_conversion_intention_id, :observed_on ],
      name: "index_wise_conversion_snapshots_on_plan_and_observed_on"
  end
end
