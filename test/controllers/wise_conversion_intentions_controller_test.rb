require "test_helper"

class WiseConversionIntentionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @family = users(:family_admin).family
    @account = accounts(:depository)
  end

  test "create creates snapshot on save" do
    ExchangeRate.create!(
      from_currency: "USD",
      to_currency: "JPY",
      date: Date.current,
      rate: 150
    )

    assert_difference -> { @family.wise_conversion_intentions.count }, 1 do
      post wise_conversion_intentions_path, params: {
        wise_conversion_intention: {
          source_account_id: @account.id,
          source_currency: "USD",
          target_currency: "JPY",
          target_amount: 1000
        }
      }
    end

    intention = @family.wise_conversion_intentions.last
    assert_equal 1, intention.wise_conversion_snapshots.count
    assert_match(/saved/i, flash[:notice])
  end

  test "create still succeeds when snapshot fetch fails" do
    ExchangeRate.stubs(:find_or_fetch_rate).raises(StandardError, "rate service down")

    assert_difference -> { @family.wise_conversion_intentions.count }, 1 do
      post wise_conversion_intentions_path, params: {
        wise_conversion_intention: {
          source_account_id: @account.id,
          source_currency: "USD",
          target_currency: "JPY",
          target_amount: 1000
        }
      }
    end

    intention = @family.wise_conversion_intentions.last
    assert_equal 1, intention.wise_conversion_snapshots.count
    assert_nil intention.wise_conversion_snapshots.last.provider_rate
    assert_match(/initial exchange rate could not be fetched/i, flash[:notice])
  end

  test "refresh updates the latest snapshot" do
    intention = @family.wise_conversion_intentions.create!(
      source_currency: "USD",
      target_currency: "JPY",
      target_amount: 1000,
      desired_rate: 150
    )

    ExchangeRate.create!(
      from_currency: "USD",
      to_currency: "JPY",
      date: Date.current,
      rate: 152
    )

    assert_difference -> { intention.wise_conversion_snapshots.count }, 1 do
      post refresh_wise_conversion_intention_path(intention)
    end
    assert_redirected_to accounts_path
  end
end
