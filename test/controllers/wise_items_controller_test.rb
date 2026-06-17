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

  test "settings panel renders even when no wise_items local is passed and OAuth is configured" do
    # Wipe the family's pre-existing wise items so the panel takes the
    # "no items" branch — this is the path that used to crash because
    # `items` was undefined when the partial was rendered directly
    # without a `wise_items` local.
    @family.wise_items.destroy_all

    with_env_overrides("WISE_CLIENT_ID" => "client-id", "WISE_CLIENT_SECRET" => "client-secret") do
      get settings_providers_url

      assert_response :success
      assert_includes response.body, "Connect with Wise"
    end
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

  test "setup account rejects linking an already-linked account" do
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
    assert_response :unprocessable_entity
  end

  test "setup account surfaces per-row error when link has no target" do
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")

    assert_no_difference -> { AccountProvider.where(provider_type: "WiseBalance").count } do
      post complete_account_setup_wise_item_url(item), params: {
        balance_actions: { balance.id => "link" }
      }
    end

    assert_response :unprocessable_entity
    assert_match(/Pick an existing account/i, response.body)
  end

  test "setup account surfaces per-row error when target is already provider-linked" do
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")
    account = accounts(:connected)  # already linked to a Plaid account

    assert_no_difference -> { AccountProvider.where(provider_type: "WiseBalance").count } do
      post complete_account_setup_wise_item_url(item), params: {
        balance_actions: { balance.id => "link" },
        existing_account_ids: { balance.id => account.id }
      }
    end

    assert_response :unprocessable_entity
  end

  test "setup account with mixed valid and invalid rows rolls back everything and renders 422" do
    item = create_wise_item
    valid_balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")
    invalid_balance = create_wise_balance(item, balance_id: "balance-eur", currency: "EUR")
    account = accounts(:depository)
    account.update!(currency: "USD")

    assert_no_difference -> { Account.where(currency: "USD").count + Account.where(currency: "EUR").count } do
      assert_no_difference -> { AccountProvider.where(provider_type: "WiseBalance").count } do
        assert_no_difference -> { WiseBalance.where(skipped: true).count } do
          post complete_account_setup_wise_item_url(item), params: {
            balance_actions: {
              valid_balance.id => "create",
              invalid_balance.id => "link"
            },
            existing_account_ids: {
              invalid_balance.id => ""
            }
          }
        end
      end
    end

    assert_response :unprocessable_entity
    refute valid_balance.reload.skipped?
    refute invalid_balance.reload.skipped?
  end

  test "setup account preserves user selections when rendering 422" do
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")

    post complete_account_setup_wise_item_url(item), params: {
      balance_actions: { balance.id => "link" },
      existing_account_ids: { balance.id => "999" }
    }

    assert_response :unprocessable_entity
    assert_match(/Pick an existing account/i, response.body)
  end

  test "setup account surfaces per-row error when two balance rows pick the same existing account" do
    item = create_wise_item
    first_balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")
    second_balance = create_wise_balance(item, balance_id: "balance-sgd", currency: "SGD")
    account = accounts(:depository)
    account.update!(currency: "USD")

    assert_no_difference -> { AccountProvider.where(provider_type: "WiseBalance").count } do
      post complete_account_setup_wise_item_url(item), params: {
        balance_actions: {
          first_balance.id => "link",
          second_balance.id => "link"
        },
        existing_account_ids: {
          first_balance.id => account.id,
          second_balance.id => account.id
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match(/another row in this form already links/i, response.body)
  end

  test "setup account re-render shows the per-row error using the correct balance key" do
    # Form params arrive with stringified keys; the view looks them up
    # via `wise_balance.id.to_s`. Without normalization, the row error
    # silently drops and the user sees the form cleared instead of
    # the rejection.
    item = create_wise_item
    balance = create_wise_balance(item, balance_id: "balance-usd", currency: "USD")

    post complete_account_setup_wise_item_url(item), params: {
      balance_actions: { balance.id => "link" },
      existing_account_ids: { balance.id => "" }
    }

    assert_response :unprocessable_entity
    assert_match(/Pick an existing account/i, response.body)
  end

  test "reauth callback flips a personal_token item to oauth and clears the token" do
    with_env_overrides("WISE_CLIENT_ID" => "client-id", "WISE_CLIENT_SECRET" => "client-secret") do
      item = create_wise_item
      item.update!(auth_mode: "personal_token", personal_token: "old-personal-token", access_token: nil, refresh_token: nil, status: :requires_update)
      get reauth_wise_item_url(item)
      state = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")

      stub_request(:post, "https://api.wise.com/oauth/token")
        .with(basic_auth: [ "client-id", "client-secret" ])
        .to_return(status: 200, body: { access_token: "fresh-token", refresh_token: "fresh-refresh", expires_in: 43_199 }.to_json)

      get reauth_callback_wise_items_url, params: { code: "auth-code", state: state }

      item.reload
      assert item.oauth?
      assert_equal "fresh-token", item.access_token
      assert_nil item.personal_token
      assert item.good?
    end
  end

  test "reauth callback requires admin" do
    with_env_overrides("WISE_CLIENT_ID" => "client-id", "WISE_CLIENT_SECRET" => "client-secret") do
      item = create_wise_item
      get reauth_wise_item_url(item)
      state = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")

      # Demote the user mid-flow: they were admin when reauth started,
      # but are no longer admin when Wise returns. The callback should
      # refuse to mutate the item.
      sign_in users(:family_member)
      get reauth_callback_wise_items_url, params: { code: "auth-code", state: state }

      assert_redirected_to accounts_url
      item.reload
      assert_not_equal "fresh-token", item.access_token
    end
  end

  test "reconnect menu link is rendered as a non-Turbo top-level link" do
    item = create_wise_item
    item.update!(status: :requires_update)

    get accounts_url

    assert_response :success
    assert_match %r{<a [^>]*data-turbo="false"[^>]*reauth}, response.body
  end

  test "reauth uses the item's stored auth_url rather than the global default" do
    with_env_overrides(
      "WISE_CLIENT_ID" => "client-id",
      "WISE_CLIENT_SECRET" => "client-secret",
      "WISE_AUTH_URL" => "https://wise.com"
    ) do
      item = create_wise_item
      item.update!(auth_url: "https://sandbox.wise.com", status: :requires_update)

      get reauth_wise_item_url(item)

      assert_match %r{\Ahttps://sandbox\.wise\.com/oauth/authorize\?}, response.location
    end
  end

  test "reauth callback exchanges the token against the item's stored base_url" do
    with_env_overrides("WISE_CLIENT_ID" => "client-id", "WISE_CLIENT_SECRET" => "client-secret") do
      item = create_wise_item
      item.update!(base_url: "https://api.sandbox.transferwise.tech", status: :requires_update)
      get reauth_wise_item_url(item)
      state = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")

      stub_request(:post, "https://api.sandbox.transferwise.tech/oauth/token")
        .with(basic_auth: [ "client-id", "client-secret" ])
        .to_return(status: 200, body: { access_token: "fresh-token", refresh_token: "fresh-refresh", expires_in: 43_199 }.to_json)

      get reauth_callback_wise_items_url, params: { code: "auth-code", state: state }

      assert_equal "fresh-token", item.reload.access_token
    end
  end

  test "setup defaults only one row to 'link' per existing account even when balances share a currency" do
    # Two same-currency balances + one matching depository. Without
    # the per-request claim tracker, both rows default to "link" with
    # the same account, the form is invalid as-is, and the user has to
    # manually switch the second row to "create" or pick a different
    # account before submitting. The defaults should be self-consistent.
    item = create_wise_item
    create_wise_balance(item, balance_id: "balance-usd-1", currency: "USD")
    create_wise_balance(item, balance_id: "balance-usd-2", currency: "USD")
    account = accounts(:depository)
    account.update!(currency: "USD")

    get setup_accounts_wise_item_url(item)

    assert_response :success
    # The first balance defaults to link; the second defaults to create
    # because the matching account is already claimed.
    assert_match(/selected="selected"[^>]*value="link"[^>]*>[\s\S]*?USD[\s\S]*?selected="selected"[^>]*value="create"/m, response.body)
  end

  test "setup preselects distinct existing accounts per row when balances share a currency and family has multiple matches" do
    # Two USD balances + two USD depositories. With claim-aware
    # account-id defaults, each row points at a distinct account so
    # the untouched form submits cleanly.
    item = create_wise_item
    first_balance = create_wise_balance(item, balance_id: "balance-usd-1", currency: "USD")
    second_balance = create_wise_balance(item, balance_id: "balance-usd-2", currency: "USD")
    first_account = accounts(:depository)
    first_account.update!(currency: "USD", name: "Example USD Checking 1111")
    second_account = Account.create!(
      family: @family,
      name: "Example USD Savings 2222",
      balance: 0,
      currency: "USD",
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "savings")
    )

    get setup_accounts_wise_item_url(item)

    assert_response :success
    # Both rows should default to "link" since we have two accounts.
    # The first row preselects the first account; the second row
    # preselects the second (because the first is already claimed).
    # We verify by parsing the rendered form: each existing_account_ids
    # select should default to a different account id.
    first_select_match = response.body.match(
      /<select[^>]*name="existing_account_ids\[#{first_balance.id}\]"[^>]*>(.*?)<\/select>/m
    )
    second_select_match = response.body.match(
      /<select[^>]*name="existing_account_ids\[#{second_balance.id}\]"[^>]*>(.*?)<\/select>/m
    )
    assert first_select_match, "expected a select for the first balance"
    assert second_select_match, "expected a select for the second balance"

    # ERB's options_from_collection_for_select can render the selected
    # attribute as `selected="selected"` (HTML) or `selected` (XHTML);
    # we accept either form to stay portable across Rails versions.
    # Account ids are UUIDs in this app, so the value regex is a
    # string-friendly variant.
    value_pattern = '"([0-9a-f-]{36})"'
    first_selected = first_select_match[1].match(/<option[^>]*selected[^>]*value=#{value_pattern}/) ||
                     first_select_match[1].match(/<option[^>]*value=#{value_pattern}[^>]*selected/)
    second_selected = second_select_match[1].match(/<option[^>]*selected[^>]*value=#{value_pattern}/) ||
                      second_select_match[1].match(/<option[^>]*value=#{value_pattern}[^>]*selected/)
    assert first_selected, "expected the first select to preselect an account"
    assert second_selected, "expected the second select to preselect an account"
    assert_not_equal first_selected[1], second_selected[1],
      "expected each row to preselect a different account"
    assert_includes [ first_account.id, second_account.id ], first_selected[1]
    assert_includes [ first_account.id, second_account.id ], second_selected[1]
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

  test "reauth loads the item and redirects to Wise using the dedicated reauth callback" do
    with_env_overrides(
      "WISE_CLIENT_ID" => "client-id",
      "WISE_CLIENT_SECRET" => "client-secret",
      "WISE_REDIRECT_URI" => "https://configured.example/wise/callback"
    ) do
      item = create_wise_item

      get reauth_wise_item_url(item)

      assert_response :redirect
      assert_match %r{\Ahttps://wise\.com/oauth/authorize\?}, response.location

      query = Rack::Utils.parse_query(URI.parse(response.location).query)
      assert_equal "client-id", query["client_id"]
      assert_equal reauth_callback_wise_items_url, query["redirect_uri"]
    end
  end

  test "reauth ignores configured WISE_REDIRECT_URI and uses dedicated callback" do
    with_env_overrides(
      "WISE_CLIENT_ID" => "client-id",
      "WISE_CLIENT_SECRET" => "client-secret",
      "WISE_REDIRECT_URI" => "https://app.example/some/other/callback"
    ) do
      item = create_wise_item

      get reauth_wise_item_url(item)

      query = Rack::Utils.parse_query(URI.parse(response.location).query)
      assert_equal reauth_callback_wise_items_url, query["redirect_uri"]
      assert_not_equal "https://app.example/some/other/callback", query["redirect_uri"]
    end
  end

  test "reauth requires admin" do
    item = create_wise_item
    sign_in users(:family_member)

    get reauth_wise_item_url(item)

    assert_redirected_to accounts_url
  end

  test "reauth requires OAuth configuration" do
    with_env_overrides("WISE_CLIENT_ID" => nil, "WISE_CLIENT_SECRET" => nil) do
      item = create_wise_item

      get reauth_wise_item_url(item)

      assert_redirected_to settings_providers_url
      assert_match(/not configured/i, flash[:alert])
    end
  end

  test "reauth_callback exchanges token using the dedicated callback URL" do
    with_env_overrides(
      "WISE_CLIENT_ID" => "client-id",
      "WISE_CLIENT_SECRET" => "client-secret",
      "WISE_REDIRECT_URI" => "https://app.example/some/other/callback"
    ) do
      item = create_wise_item
      get reauth_wise_item_url(item)
      state = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")

      stub_request(:post, "https://api.wise.com/oauth/token")
        .with(
          basic_auth: [ "client-id", "client-secret" ],
          body: hash_including("grant_type" => "authorization_code", "code" => "auth-code", "redirect_uri" => reauth_callback_wise_items_url)
        )
        .to_return(status: 200, body: { access_token: "fresh-token", refresh_token: "fresh-refresh", expires_in: 43_199 }.to_json)

      get reauth_callback_wise_items_url, params: { code: "auth-code", state: state }

      assert_redirected_to accounts_url
      assert_equal "fresh-token", item.reload.access_token
    end
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
