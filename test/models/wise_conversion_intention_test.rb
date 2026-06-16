require "test_helper"

class WiseConversionIntentionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "creates snapshot with percentile and target status" do
    30.downto(0).each do |offset|
      ExchangeRate.create!(
        from_currency: "USD",
        to_currency: "SGD",
        date: Date.current - offset.days,
        rate: BigDecimal("1.30") + (BigDecimal(offset.to_s) / 1000)
      )
    end

    intention = WiseConversionIntention.create!(
      family: @family,
      source_currency: "USD",
      target_currency: "SGD",
      target_amount: 1000,
      desired_rate: 1.35
    )

    snapshot = intention.refresh_snapshot!(observed_on: Date.current)

    assert snapshot.persisted?
    assert_equal BigDecimal("1.30"), snapshot.provider_rate
    assert_equal "below_target", intention.target_status
    assert snapshot.rate_30d_percentile.present?
  end

  test "uses near target language without financial advice" do
    ExchangeRate.create!(
      from_currency: "USD",
      to_currency: "SGD",
      date: Date.current,
      rate: 1.295
    )

    intention = WiseConversionIntention.create!(
      family: @family,
      source_currency: "USD",
      target_currency: "SGD",
      desired_rate: 1.30
    )
    intention.refresh_snapshot!(observed_on: Date.current)

    assert_equal "near_target", intention.target_status
    refute_match(/convert now/i, intention.target_status_label)
  end

  test "does not show percentiles with sparse exchange-rate history" do
    ExchangeRate.create!(
      from_currency: "USD",
      to_currency: "MYR",
      date: Date.current,
      rate: 4.70
    )
    intention = WiseConversionIntention.create!(
      family: @family,
      source_currency: "USD",
      target_currency: "MYR",
      desired_rate: 4.80
    )

    snapshot = intention.refresh_snapshot!(observed_on: Date.current)

    assert_equal BigDecimal("4.7"), snapshot.provider_rate
    assert_nil snapshot.rate_30d_percentile
    assert_nil snapshot.rate_90d_percentile
    assert_nil snapshot.rate_365d_percentile
  end

  test "returns nil provider rate when exchange-rate lookup raises" do
    intention = WiseConversionIntention.create!(
      family: @family,
      source_currency: "USD",
      target_currency: "JPY",
      desired_rate: 150
    )

    ExchangeRate.stubs(:find_or_fetch_rate).raises(StandardError, "rate service down")

    snapshot = intention.refresh_snapshot!(observed_on: Date.current)

    assert_nil snapshot.provider_rate
    assert_nil snapshot.rate_30d_percentile
    assert_equal "tracking", intention.target_status
  end
end
