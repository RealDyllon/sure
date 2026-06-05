require "application_system_test_case"

class WiseProviderTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
  end

  test "shows Wise provider accounts cards and conversion plans" do
    wise_item = @family.wise_items.create!(
      name: "Wise Connection",
      auth_mode: "oauth",
      access_token: "access-token",
      refresh_token: "refresh-token"
    )
    wise_balance = wise_item.wise_balances.create!(
      balance_id: "balance-sgd",
      name: "Wise SGD",
      currency: "SGD",
      balance_type: "STANDARD",
      current_balance: 100
    )
    wise_item.wise_cards.create!(
      wise_card_id: "card-1",
      card_type: "VIRTUAL",
      status: "ACTIVE",
      last_four: "4242",
      expiry_month: 12,
      expiry_year: 2028
    )
    account = Account.create_and_sync(
      {
        family: @family,
        name: "Wise SGD",
        balance: 100,
        currency: "SGD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )
    AccountProvider.create!(account: account, provider: wise_balance)
    plan = @family.wise_conversion_intentions.create!(
      source_account: account,
      source_currency: "SGD",
      target_currency: "JPY",
      target_amount: 1000,
      desired_rate: 120
    )
    plan.wise_conversion_snapshots.create!(
      provider_rate: 108,
      rate_90d_percentile: 63,
      observed_on: Date.current
    )

    visit accounts_path

    assert_text "Wise Connection"
    assert_text "Wise SGD"
    assert_text "Wise cards"
    assert_text "4242"
    assert_text "Conversion plans"
    assert_text "SGD to JPY"
    assert_text "Below target"
  end
end
