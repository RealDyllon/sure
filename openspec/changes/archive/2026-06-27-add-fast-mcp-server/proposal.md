## Why

The application already exposes a hand-rolled JSON-RPC MCP endpoint at `POST /mcp` so external AI assistants can query financial data. That endpoint only supports HTTP POST and requires the client to handle raw JSON-RPC framing. Using [fast-mcp](https://github.com/yjacquin/fast-mcp) gives us a standards-compliant MCP server with SSE/HTTP transports, built-in JSON Schema validation, tool annotations, and trivial integration with clients such as Claude Desktop and Cursor.

## What Changes

- Add the `fast-mcp` gem to the Gemfile.
- Mount a new fast-mcp server in Rails at `/mcp/fast` (SSE + messages endpoints) without removing the existing `POST /mcp` controller.
- Reuse the existing `MCP_API_TOKEN` and `MCP_USER_EMAIL` environment variables for authentication and user resolution.
- Wrap the existing `Assistant::Function` classes as fast-mcp tools in `app/tools/`:
  - `get_accounts`
  - `get_transactions`
  - `get_holdings`
  - `get_balance_sheet`
  - `get_income_statement`
  - `import_bank_statement`
  - `search_family_files`
- Add integration tests for the new MCP endpoint.
- Document the new SSE endpoint and a sample Claude Desktop configuration.

## Capabilities

### New Capabilities

- `fast-mcp-server`: Expose a standards-compliant MCP server over SSE/HTTP that authenticates via bearer token and exposes financial read-only tools backed by the existing assistant functions.

### Modified Capabilities

- None. Existing assistant function behavior remains unchanged; only a new transport/tool adapter is added.

## Impact

- New dependency: `fast-mcp` (Ruby 3.0+, Rack 2/3 compatible).
- New initializer: `config/initializers/fast_mcp.rb`.
- New directory: `app/tools/` with an `ApplicationTool` base class and tool wrappers.
- New integration tests under `test/controllers/fast_mcp_controller_test.rb`.
- New env-var documentation in `.env.local.example` and `AGENTS.md`.
- No breaking changes to the existing `/mcp` controller or assistant functions.
