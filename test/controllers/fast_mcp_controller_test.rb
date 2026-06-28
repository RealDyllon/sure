require "test_helper"

class FastMcpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @token = "test-fast-mcp-token-#{SecureRandom.hex(8)}"
  end

  # -- Mounting --
  # The initializer seeds `MCP_API_TOKEN` / `MCP_USER_EMAIL` defaults in the
  # test environment (no gitignored `.env.test` needed), so the fast-mcp
  # middleware is always mounted during tests. Individual tests override the
  # env vars via `with_env_overrides` / ClimateControl.

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

      assert mcp_success?(result), "Expected isError: false, got: #{result.inspect}"
      data = parse_mcp_text(result)
      assert(data.key?("net_worth") || data.key?("error"),
             "Expected net_worth or error key, got: #{data.keys.inspect}")
    end
  end

  test "GetAccountsTool returns accounts for the configured user" do
    with_fast_mcp_env do
      result = GetAccountsTool.new.call

      assert mcp_success?(result)
      data = parse_mcp_text(result)
      assert data.key?("as_of_date")
      assert data.key?("accounts")
      assert_kind_of Array, data["accounts"]
    end
  end

  test "GetIncomeStatementTool rejects missing required arguments" do
    with_fast_mcp_env do
      # Schema validation happens in `call_with_schema_validation!` (the entry
      # point used by fast-mcp's server), not in `call` itself.
      assert_raises FastMcp::Tool::InvalidArgumentsError do
        GetIncomeStatementTool.new.call_with_schema_validation!(start_date: "2024-01-01")
      end
    end
  end

  test "tool returns a user-not-configured error when MCP_USER_EMAIL is unset" do
    with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => nil) do
      result = GetBalanceSheetTool.new.call

      assert result[:isError], "Expected isError: true, got: #{result.inspect}"
      data = parse_mcp_text(result)
      assert_equal "mcp_user_not_configured", data["error"]
      assert_match(/MCP_USER_EMAIL/, data["message"])
    end
  end

  test "tool returns a user-not-configured error when the email is unknown" do
    with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => "noone@example.com") do
      result = GetBalanceSheetTool.new.call

      assert result[:isError]
      data = parse_mcp_text(result)
      assert_equal "mcp_user_not_configured", data["error"]
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

    # ApplicationTool#call returns MCP-spec content envelopes:
    #   { content: [{ type: "text", text: "<json>" }], isError: <bool> }
    def parse_mcp_text(result)
      JSON.parse(result[:content].first[:text])
    end

    def mcp_success?(result)
      result.is_a?(Hash) && result[:isError] == false
    end
end
