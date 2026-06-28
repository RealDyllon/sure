## 1. Setup

- [x] 1.1 Add `gem "fast-mcp"` to the Gemfile and run `bundle install` in the worktree.
- [x] 1.2 Verify `fast-mcp` loads correctly in a Rails console.

## 2. Mount fast-mcp in Rails

- [x] 2.1 Create `config/initializers/fast_mcp.rb` that calls `FastMcp.mount_in_rails` with:
  - `name: "sure"`
  - `version: "1.0.0"`
  - `path_prefix: "/mcp/fast"`
  - `authenticate: true` and `auth_token: ENV["MCP_API_TOKEN"]`
  - `allowed_origins:` derived from `Rails.application.config.hosts` plus localhost defaults
- [x] 2.2 In the mount block, register `ApplicationTool.descendants` after Rails initialization.
- [x] 2.3 Ensure the middleware does not trigger Rails CSRF/session callbacks for `/mcp/fast/*`.

## 3. Create tool base class and wrappers

- [x] 3.1 Create `app/tools/application_tool.rb` inheriting from `ActionTool::Base`.
- [x] 3.2 Add a `current_user` helper that resolves the user from `ENV["MCP_USER_EMAIL"]` and sets `Current.session` to a fresh session.
- [x] 3.3 Create `app/tools/get_accounts_tool.rb` that delegates to `Assistant::Function::GetAccounts`.
- [x] 3.4 Create `app/tools/get_transactions_tool.rb` with Dry::Schema arguments matching the existing `params_schema`.
- [x] 3.5 Create `app/tools/get_holdings_tool.rb` with Dry::Schema arguments matching the existing `params_schema`.
- [x] 3.6 Create `app/tools/get_balance_sheet_tool.rb` that delegates to `Assistant::Function::GetBalanceSheet`.
- [x] 3.7 Create `app/tools/get_income_statement_tool.rb` with Dry::Schema arguments matching the existing `params_schema`.
- [x] 3.8 Create `app/tools/import_bank_statement_tool.rb` marked with `read_only_hint: false` and `destructive_hint: true`.
- [x] 3.9 Create `app/tools/search_family_files_tool.rb` with a required `query` argument.
- [x] 3.10 Verify all tool wrappers return JSON-serializable results and handle errors gracefully.

## 4. Authentication and user context

- [x] 4.1 Implement a request-level hook that resets `ActiveSupport::CurrentAttributes` and builds a fresh `Session` for the MCP user before each tool call.
- [x] 4.2 Return HTTP 503 with a clear error when `MCP_USER_EMAIL` is missing or the user cannot be found.
- [x] 4.3 Confirm the same `Authorization: Bearer <token>` format works for both SSE and messages endpoints.

## 5. Tests

- [x] 5.1 Create `test/controllers/fast_mcp_controller_test.rb` with tests for:
  - Missing/invalid token returns 401
  - Missing/invalid `MCP_USER_EMAIL` returns 503
  - `GET /mcp/fast/sse` returns an SSE stream with an endpoint event
  - `tools/list` returns all seven tool names
  - `tools/call` for `get_balance_sheet` returns JSON text content
  - `tools/call` for an unknown tool returns a JSON-RPC error
- [x] 5.2 Run the existing `McpControllerTest` suite to confirm `/mcp` is unchanged.
- [x] 5.3 Run `bin/rubocop` on new files and auto-correct safe offenses.

## 6. Documentation

- [x] 6.1 Add `MCP_API_TOKEN` and `MCP_USER_EMAIL` entries to `.env.local.example`.
- [x] 6.2 Add a section to `AGENTS.md` describing the new SSE endpoint and a Claude Desktop config snippet.
- [x] 6.3 Add a note that the legacy `POST /mcp` endpoint remains available.

## 7. Verification

- [x] 7.1 Start the Rails server and verify `GET /mcp/fast/sse` responds with a valid SSE stream.
- [x] 7.2 Use `npx @modelcontextprotocol/inspector` or curl to verify `tools/list` and `tools/call`.
- [x] 7.3 Run the full test suite (`bin/rails test`) and ensure it is green.
