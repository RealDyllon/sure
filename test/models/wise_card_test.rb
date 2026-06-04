require "test_helper"

class WiseCardTest < ActiveSupport::TestCase
  setup do
    @wise_item = WiseItem.create!(
      family: families(:dylan_family),
      name: "Wise Connection",
      auth_mode: "oauth",
      access_token: "access-token",
      refresh_token: "refresh-token"
    )
  end

  test "upserts non-sensitive card metadata only" do
    card = @wise_item.wise_cards.find_or_initialize_by(wise_card_id: "card-token-1")
    card.upsert_wise_snapshot!(
      token: "card-token-1",
      cardProgram: { type: "VIRTUAL" },
      status: { type: "ACTIVE" },
      lastFourDigits: "4242",
      expiryDate: "2028-12-31T00:00:00Z",
      pan: "redacted-pan-token",
      cvv: "123",
      nested: { pin: "9999", safe: "kept" }
    )

    assert_equal "card-token-1", card.wise_card_id
    assert_equal "4242", card.last_four
    assert_equal "VIRTUAL", card.card_type
    assert_equal "ACTIVE", card.status
    assert_equal 12, card.expiry_month
    assert_equal 2028, card.expiry_year
    refute card.raw_payload.key?("pan")
    refute card.raw_payload.key?("cvv")
    refute card.raw_payload["nested"].key?("pin")
    assert_equal "kept", card.raw_payload["nested"]["safe"]
    assert_nil AccountProvider.find_by(provider: card)
  end
end
