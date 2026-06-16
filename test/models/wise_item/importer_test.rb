require "test_helper"

class WiseItem::ImporterTest < ActiveSupport::TestCase
  class FakeWiseProvider
    attr_reader :statement_calls

    def initialize
      @statement_calls = []
    end

    def get_profiles
      [ { id: "profile-1", type: "personal", fullName: "Example User" } ]
    end

    def get_balances(profile_id:)
      [
        { id: "balance-usd", type: "STANDARD", currency: "USD", amount: { value: "100.00", currency: "USD" } },
        { id: "balance-jar", type: "SAVINGS", currency: "USD", amount: { value: "50.00", currency: "USD" } }
      ]
    end

    def get_cards(profile_id:)
      [ { token: "card-token-1", cardProgram: { type: "VIRTUAL" }, status: { type: "ACTIVE" }, lastFourDigits: "4242", expiryDate: "2028-12-31T00:00:00Z" } ]
    end

    def get_balance_statement(profile_id:, balance_id:, currency:, interval_start:, interval_end:)
      @statement_calls << {
        profile_id: profile_id,
        balance_id: balance_id,
        currency: currency,
        interval_start: interval_start,
        interval_end: interval_end
      }
      { transactions: [] }
    end
  end

  setup do
    @wise_item = WiseItem.create!(
      family: families(:dylan_family),
      name: "Wise Connection",
      auth_mode: "oauth",
      access_token: "access-token",
      refresh_token: "refresh-token",
      sync_start_date: Date.new(2024, 1, 1)
    )
  end

  test "imports only standard balances and card metadata" do
    provider = FakeWiseProvider.new

    assert_difference -> { @wise_item.wise_balances.count }, 1 do
      assert_difference -> { @wise_item.wise_cards.count }, 1 do
        WiseItem::Importer.new(@wise_item, wise_provider: provider).import
      end
    end

    assert_equal "balance-usd", @wise_item.wise_balances.sole.balance_id
    assert_equal "STANDARD", @wise_item.wise_balances.sole.balance_type
    assert_equal "card-token-1", @wise_item.wise_cards.sole.wise_card_id
    assert_equal "4242", @wise_item.wise_cards.sole.last_four
    assert @wise_item.reload.pending_account_setup?
  end

  test "chunks linked balance statements to at most 469 days" do
    provider = FakeWiseProvider.new
    balance = @wise_item.wise_balances.create!(
      balance_id: "balance-usd",
      profile_id: "profile-1",
      name: "Wise USD",
      currency: "USD",
      balance_type: "STANDARD",
      current_balance: 100
    )
    account = Account.create_and_sync(
      {
        family: @wise_item.family,
        name: "Wise USD",
        balance: 100,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )
    AccountProvider.create!(account: account, provider: balance)

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert provider.statement_calls.any?
    provider.statement_calls.each do |call|
      days = (call[:interval_end].to_date - call[:interval_start].to_date).to_i + 1
      assert_operator days, :<=, WiseItem::Importer::MAX_STATEMENT_DAYS
    end
  end

  test "uses refreshed OAuth token for import requests" do
    @wise_item.update!(access_token: "expired-token", token_expires_at: 1.minute.ago)
    stub_request(:post, "https://api.wise.com/oauth/token")
      .with(basic_auth: [ "client-id", "client-secret" ])
      .to_return(status: 200, body: { access_token: "fresh-token", refresh_token: "refresh-token", expires_in: 43_199 }.to_json)
    stub_request(:get, "https://api.wise.com/v1/profiles")
      .with(headers: { "Authorization" => "Bearer fresh-token" })
      .to_return(status: 200, body: [ { id: "profile-1", type: "personal", fullName: "Example User" } ].to_json)
    stub_request(:get, "https://api.wise.com/v4/profiles/profile-1/balances?types=STANDARD")
      .with(headers: { "Authorization" => "Bearer fresh-token" })
      .to_return(status: 200, body: { balances: [] }.to_json)
    stub_request(:get, "https://api.wise.com/v3/spend/profiles/profile-1/cards")
      .with(headers: { "Authorization" => "Bearer fresh-token" })
      .to_return(status: 200, body: { cards: [] }.to_json)

    with_env_overrides("WISE_CLIENT_ID" => "client-id", "WISE_CLIENT_SECRET" => "client-secret") do
      WiseItem::Importer.new(@wise_item, wise_provider: Provider::Wise.new(access_token: "expired-token")).import
    end

    assert_equal "fresh-token", @wise_item.reload.access_token
    assert_requested :get, "https://api.wise.com/v1/profiles",
      headers: { "Authorization" => "Bearer fresh-token" }
  end

  test "derives connected_institutions from per-balance metadata" do
    @wise_item.wise_balances.create!(
      balance_id: "balance-sgd",
      profile_id: "profile-1",
      name: "Wise SGD",
      currency: "SGD",
      balance_type: "STANDARD",
      current_balance: 100,
      institution_metadata: { "name" => "Wise", "domain" => "wise.com", "color" => "#00B9FF" }
    )

    institutions = @wise_item.connected_institutions
    assert_equal 1, institutions.size
    assert_equal "Wise", institutions.first["name"]
  end
end
