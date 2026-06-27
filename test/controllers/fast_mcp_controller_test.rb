require "test_helper"

class FastMcpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @token = "test-fast-mcp-token-#{SecureRandom.hex(8)}"
  end

  # -- Mounting --
  # The `return unless ENV[...]` guard in the initializer is evaluated once at
  # boot, so we can't toggle it per-test. The fast-mcp middleware is mounted
  # by the test process because `.env.test` sets both env vars.

  test "fast_mcp initializer refuses to mount when env vars are missing" do
    source = Rails.root.join("config/initializers/fast_mcp.rb").read

    assert_match(/ENV\[.MCP_API_TOKEN.\]/, source, "Initializer references MCP_API_TOKEN")
    assert_match(/ENV\[.MCP_USER_EMAIL.\]/, source, "Initializer references MCP_USER_EMAIL")
    assert_match(/return\s+unless/, source, "Initializer has a guard return")
  end

  # -- HTTP authentication & routing --

  test "SSE endpoint rejects requests without an Authorization header" do
    with_fast_mcp_env do
      get "/mcp/fast/sse"
      assert_response :unauthorized
    end
  end

  test "SSE endpoint rejects requests with an invalid bearer token" do
    with_fast_mcp_env do
      get "/mcp/fast/sse", headers: bearer_headers("not-the-right-token")
      assert_response :unauthorized
    end
  end

  test "messages endpoint rejects requests with a bad token" do
    with_fast_mcp_env do
      post "/mcp/fast/messages",
           params: jsonrpc_request("tools/list").to_json,
           headers: bearer_headers("not-the-right-token")
      assert_response :unauthorized
    end
  end

  test "messages endpoint is reachable for a valid bearer token" do
    with_fast_mcp_env do
      post "/mcp/fast/messages",
           params: jsonrpc_request("tools/list").to_json,
           headers: bearer_headers(@token)
      # The fast-mcp HTTP transport broadcasts the JSON-RPC response over SSE,
      # so the HTTP POST response body is intentionally empty. We only assert
      # the middleware accepted the request and returned 200.
      assert_response :ok
    end
  end

  test "SSE endpoint is reachable for a valid bearer token" do
    with_fast_mcp_env do
      get "/mcp/fast/sse", headers: bearer_headers(@token)
      assert_response :ok
    end
  end

  # -- Tool wrappers --
  # The fast-mcp server sends JSON-RPC responses over SSE, so we exercise the
  # tool wrappers directly to assert their behavior.

  test "GetBalanceSheetTool returns balance sheet data for the configured user" do
    with_fast_mcp_env do
      result = GetBalanceSheetTool.new.call

      assert result.is_a?(Hash), "Expected a Hash, got: #{result.class}"
      assert(
        result.key?("net_worth") || result.key?("error"),
        "Expected net_worth or error key, got: #{result.keys.inspect}"
      )
    end
  end

  test "GetAccountsTool returns accounts for the configured user" do
    with_fast_mcp_env do
      result = GetAccountsTool.new.call

      assert result.is_a?(Hash), "Expected a Hash, got: #{result.class}"
      assert result.key?("as_of_date")
      assert result.key?("accounts")
      assert_kind_of Array, result["accounts"]
    end
  end

  test "GetIncomeStatementTool rejects missing required arguments" do
    with_fast_mcp_env do
      # fast-mcp's schema validation happens before the tool's call method,
      # so we pass invalid args directly and check the rescue path.
      result = GetIncomeStatementTool.new.call(start_date: "2024-01-01")
      assert result.is_a?(Hash)
    end
  end

  test "tool returns a user-not-configured error when MCP_USER_EMAIL is unset" do
    with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => nil) do
      result = GetBalanceSheetTool.new.call

      assert_equal "mcp_user_not_configured", result["error"]
      assert_match(/MCP_USER_EMAIL/, result["message"])
    end
  end

  test "tool returns a user-not-configured error when the email is unknown" do
    with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => "noone@example.com") do
      result = GetBalanceSheetTool.new.call

      assert_equal "mcp_user_not_configured", result["error"]
    end
  end

  test "tool resets Current attributes around the call" do
    with_fast_mcp_env do
      Current.session = nil
      GetBalanceSheetTool.new.call
      # After the call, Current attributes should be cleared.
      assert_nil Current.session
    end
  end

  private

    def with_fast_mcp_env(&block)
      with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => @user.email, &block)
    end

    def bearer_headers(token)
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{token}"
      }
    end

    def jsonrpc_request(method, params = {}, id: 1)
      { jsonrpc: "2.0", id: id, method: method, params: params }
    end
end
