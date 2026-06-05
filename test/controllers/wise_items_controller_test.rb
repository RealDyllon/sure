require "test_helper"

class WiseItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @family = families(:dylan_family)
  end

  test "settings panel renders Wise beta and personal-token limitation" do
    get settings_providers_url

    assert_response :success
    assert_includes response.body, "Wise (beta)"
    assert_includes response.body, "limited endpoint access"
  end

  test "oauth callback error redirects with alert" do
    get oauth_callback_wise_items_url, params: { error: "access_denied", error_description: "Denied" }

    assert_redirected_to settings_providers_url
    assert_equal "Wise authorization failed: Denied", flash[:alert]
  end

  test "oauth callback rejects missing stored state" do
    with_env_overrides("WISE_CLIENT_ID" => "client-id", "WISE_CLIENT_SECRET" => "client-secret") do
      stub_request(:post, "https://api.wise.com/oauth/token")

      assert_no_difference -> { @family.wise_items.count } do
        get oauth_callback_wise_items_url, params: { code: "attacker-code" }
      end

      assert_redirected_to settings_providers_url
      assert_equal "Wise authorization state did not match. Please try again.", flash[:alert]
      assert_not_requested :post, "https://api.wise.com/oauth/token"
    end
  end

  test "oauth callback stores selected Wise profile" do
    with_env_overrides("WISE_CLIENT_ID" => "client-id", "WISE_CLIENT_SECRET" => "client-secret") do
      get oauth_start_wise_items_url

      state = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")
      stub_request(:post, "https://api.wise.com/oauth/token")
        .with(basic_auth: [ "client-id", "client-secret" ])
        .to_return(status: 200, body: { access_token: "access-token", refresh_token: "refresh-token", expires_in: 43_199 }.to_json)

      assert_difference -> { @family.wise_items.count }, 1 do
        get oauth_callback_wise_items_url, params: { code: "auth-code", state: state, profileId: "profile-2" }
      end

      assert_redirected_to accounts_url
      assert_equal "profile-2", @family.wise_items.order(:created_at).last.profile_id
    end
  end

  test "oauth callback uses and stores configured Wise OAuth hosts" do
    with_env_overrides(
      "WISE_CLIENT_ID" => "client-id",
      "WISE_CLIENT_SECRET" => "client-secret",
      "WISE_AUTH_URL" => "https://sandbox.wise.com",
      "WISE_BASE_URL" => "https://api.sandbox.transferwise.tech"
    ) do
      get oauth_start_wise_items_url

      state = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")
      stub_request(:post, "https://api.sandbox.transferwise.tech/oauth/token")
        .with(basic_auth: [ "client-id", "client-secret" ])
        .to_return(status: 200, body: { access_token: "access-token", refresh_token: "refresh-token" }.to_json)

      assert_difference -> { @family.wise_items.count }, 1 do
        get oauth_callback_wise_items_url, params: { code: "auth-code", state: state }
      end

      item = @family.wise_items.order(:created_at).last
      assert_equal "https://api.sandbox.transferwise.tech", item.base_url
      assert_equal "https://sandbox.wise.com", item.auth_url
    end
  end

  test "creates limited personal token item" do
    assert_difference -> { @family.wise_items.count }, 1 do
      post wise_items_url, params: {
        wise_item: {
          personal_token: "example-personal-token",
          base_url: "https://api.sandbox.transferwise.tech"
        }
      }
    end

    item = @family.wise_items.order(:created_at).last
    assert item.personal_token?
    assert_equal "example-personal-token", item.personal_token
    assert_redirected_to accounts_url
  end

  test "setup account creates Wise depository account" do
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")

    assert_difference -> { AccountProvider.where(provider_type: "WiseBalance").count }, 1 do
      assert_difference -> { @family.accounts.where(accountable_type: "Depository", currency: "USD").count }, 1 do
        post complete_account_setup_wise_item_url(item), params: {
          balance_actions: { balance.id => "create" }
        }
      end
    end

    assert_redirected_to accounts_url
    assert_equal @family.accounts.order(:created_at).last, balance.reload.current_account
  end

  test "setup account links existing depository account" do
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-sgd", currency: "SGD")
    account = accounts(:depository)
    account.update!(currency: "SGD")

    assert_difference -> { AccountProvider.where(provider_type: "WiseBalance").count }, 1 do
      post complete_account_setup_wise_item_url(item), params: {
        balance_actions: { balance.id => "link" },
        existing_account_ids: { balance.id => account.id }
      }
    end

    assert_equal account, balance.reload.current_account
  end

  test "setup account skip persists and clears setup required state" do
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-eur", currency: "EUR")
    item.update!(pending_account_setup: true)

    post complete_account_setup_wise_item_url(item), params: {
      balance_actions: { balance.id => "skip" }
    }

    assert_redirected_to accounts_url
    assert balance.reload.skipped?
    refute item.reload.pending_account_setup?
  end

  test "setup account does not link legacy provider account" do
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")
    account = accounts(:connected)

    assert_no_difference -> { AccountProvider.where(provider_type: "WiseBalance").count } do
      post complete_account_setup_wise_item_url(item), params: {
        balance_actions: { balance.id => "link" },
        existing_account_ids: { balance.id => account.id }
      }
    end

    assert_nil balance.reload.current_account
  end

  test "direct Wise link rejects legacy provider account" do
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")
    account = accounts(:connected)

    assert_no_difference -> { AccountProvider.where(provider_type: "WiseBalance").count } do
      post link_existing_account_wise_items_url, params: {
        account_id: account.id,
        wise_balance_id: balance.id
      }
    end

    assert_redirected_to accounts_url
    assert_equal "This account is already linked.", flash[:alert]
  end

  test "direct Wise link rejects protocol-relative return path" do
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")
    account = accounts(:depository)
    account.update!(currency: "USD")

    post link_existing_account_wise_items_url, params: {
      account_id: account.id,
      wise_balance_id: balance.id,
      return_to: "//evil.example"
    }

    assert_redirected_to accounts_url
  end

  test "sync creates one visible sync when not already syncing" do
    item = create_wise_item

    assert_difference -> { item.syncs.count }, 1 do
      post sync_wise_item_url(item)
    end

    assert_redirected_to accounts_url
  end

  test "destroy unlinks provider links and schedules deletion" do
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")
    AccountProvider.create!(account: accounts(:depository), provider: balance)

    assert_difference -> { AccountProvider.where(provider_type: "WiseBalance").count }, -1 do
      delete wise_item_url(item)
    end

    assert item.reload.scheduled_for_deletion?
    assert_redirected_to accounts_url
  end

  private

    def create_wise_item
      @family.wise_items.create!(
        name: "Wise Connection",
        auth_mode: "oauth",
        access_token: "access-token",
        refresh_token: "refresh-token"
      )
    end

    def create_wise_balance(item, balance_id:, currency:)
      item.wise_balances.create!(
        balance_id: balance_id,
        name: "Wise #{currency}",
        currency: currency,
        balance_type: "STANDARD",
        current_balance: 100
      )
    end
end
