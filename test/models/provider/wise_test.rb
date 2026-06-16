require "test_helper"

class Provider::WiseTest < ActiveSupport::TestCase
  test "uses documented production OAuth hosts" do
    with_env_overrides("WISE_CLIENT_ID" => "client-id", "WISE_CLIENT_SECRET" => "client-secret", "WISE_AUTH_URL" => nil, "WISE_BASE_URL" => nil) do
      authorize_url = Provider::Wise.oauth_authorize_url(redirect_uri: "https://sure.example/wise/callback", state: "state-token")

      assert_match %r{\Ahttps://wise\.com/oauth/authorize\?}, authorize_url
      assert_equal "https://api.wise.com", Provider::Wise.oauth_base_url
      assert_includes authorize_url, "client_id=client-id"
    end
  end

  test "uses configured OAuth API base URL" do
    with_env_overrides("WISE_BASE_URL" => "https://api.sandbox.transferwise.tech") do
      assert_equal "https://api.sandbox.transferwise.tech", Provider::Wise.oauth_base_url
    end
  end

  test "exchanges OAuth codes against the Wise API host" do
    stub_request(:post, "https://api.wise.com/oauth/token")
      .with(
        basic_auth: [ "client-id", "client-secret" ],
        body: hash_including("grant_type" => "authorization_code", "code" => "auth-code")
      )
      .to_return(status: 200, body: { access_token: "access-token", refresh_token: "refresh-token" }.to_json)

    provider = Provider::Wise.new(access_token: "", client_id: "client-id", client_secret: "client-secret")

    assert_equal "access-token", provider.exchange_code_for_token(code: "auth-code", redirect_uri: "https://sure.example/callback")[:access_token]
  end

  test "refreshes OAuth tokens with basic authentication" do
    stub_request(:post, "https://api.wise.com/oauth/token")
      .with(
        basic_auth: [ "client-id", "client-secret" ],
        body: hash_including("grant_type" => "refresh_token", "refresh_token" => "refresh-token")
      )
      .to_return(status: 200, body: { access_token: "fresh-token", refresh_token: "refresh-token" }.to_json)

    provider = Provider::Wise.new(
      access_token: "expired-token",
      refresh_token: "refresh-token",
      client_id: "client-id",
      client_secret: "client-secret"
    )

    assert_equal "fresh-token", provider.refresh_access_token[:access_token]
  end

  test "uses Wise spend card endpoint" do
    stub_request(:get, "https://api.wise.com/v3/spend/profiles/profile-1/cards")
      .with(headers: { "Authorization" => "Bearer access-token" })
      .to_return(status: 200, body: { cards: [ { token: "card-token" } ] }.to_json)

    provider = Provider::Wise.new(access_token: "access-token")

    assert_equal [ { token: "card-token" } ], provider.get_cards(profile_id: "profile-1")[:cards]
  end

  test "sends bearer token when fetching profiles" do
    stub_request(:get, "https://api.wise.com/v1/profiles")
      .with(headers: { "Authorization" => "Bearer access-token" })
      .to_return(status: 200, body: [ { id: "profile-1", type: "personal" } ].to_json)

    provider = Provider::Wise.new(access_token: "access-token")

    assert_equal [ { id: "profile-1", type: "personal" } ], provider.get_profiles
  end

  test "maps unauthorized response to Wise error" do
    stub_request(:get, "https://api.wise.com/v1/profiles")
      .to_return(status: 401, body: "{}")

    error = assert_raises Provider::Wise::WiseError do
      Provider::Wise.new(access_token: "bad-token").get_profiles
    end

    assert_equal :unauthorized, error.error_type
  end

  test "surfaces Wise's error message in WiseError" do
    stub_request(:get, "https://api.wise.com/v1/profiles")
      .to_return(status: 401, body: { error: "Token has expired" }.to_json)

    error = assert_raises Provider::Wise::WiseError do
      Provider::Wise.new(access_token: "stale-token").get_profiles
    end

    assert_equal "Token has expired", error.message
    assert_equal :unauthorized, error.error_type
  end

  test "connection_configs returns a setup config for families with no Wise item" do
    with_env_overrides("WISE_CLIENT_ID" => "client-id", "WISE_CLIENT_SECRET" => "client-secret") do
      family = families(:empty)

      configs = Provider::WiseAdapter.connection_configs(family: family)

      assert_equal 1, configs.size
      assert_equal "wise", configs.first[:key]
      assert_match(/OAuth/i, configs.first[:description])
    end
  end

  test "connection_configs returns a balance-setup config when an item exists" do
    with_env_overrides("WISE_CLIENT_ID" => "client-id", "WISE_CLIENT_SECRET" => "client-secret") do
      family = families(:dylan_family)
      wise_items(:dylan_wise_oauth)

      configs = Provider::WiseAdapter.connection_configs(family: family)

      assert_equal 1, configs.size
      assert_equal "wise", configs.first[:key]
      assert_match(/currency balance/i, configs.first[:description])
    end
  end

  test "connection_configs returns [] when OAuth is not configured" do
    with_env_overrides("WISE_CLIENT_ID" => nil, "WISE_CLIENT_SECRET" => nil) do
      family = families(:empty)

      assert_empty Provider::WiseAdapter.connection_configs(family: family)
    end
  end
end
