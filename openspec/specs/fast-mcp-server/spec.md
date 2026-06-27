# fast-mcp-server Specification

## Purpose
TBD - created by archiving change add-fast-mcp-server. Update Purpose after archive.
## Requirements
### Requirement: Server exposes MCP endpoints over SSE and HTTP messages
The system SHALL mount a fast-mcp server at `/mcp/fast` providing an SSE endpoint and a messages endpoint for JSON-RPC communication.

#### Scenario: Client connects via SSE
- **WHEN** an authenticated client opens `GET /mcp/fast/sse`
- **THEN** the server returns an SSE stream with an `endpoint` event pointing to `/mcp/fast/messages`

#### Scenario: Client sends a JSON-RPC message
- **WHEN** an authenticated client posts a valid JSON-RPC request to `POST /mcp/fast/messages`
- **THEN** the server returns a JSON-RPC 2.0 response

### Requirement: Server authenticates requests with a bearer token
The system SHALL reject unauthenticated or invalid requests to `/mcp/fast/*` with HTTP 401 Unauthorized.

#### Scenario: Missing authorization header
- **WHEN** a request is made to `/mcp/fast/sse` without an `Authorization` header
- **THEN** the server responds with HTTP 401 Unauthorized

#### Scenario: Invalid bearer token
- **WHEN** a request is made to `/mcp/fast/*` with an `Authorization` header that does not match `MCP_API_TOKEN`
- **THEN** the server responds with HTTP 401 Unauthorized

#### Scenario: Valid bearer token
- **WHEN** a request is made to `/mcp/fast/*` with an `Authorization: Bearer <MCP_API_TOKEN>` header
- **THEN** the server authenticates the request and resolves the acting user from `MCP_USER_EMAIL`

### Requirement: Server exposes financial tools via tools/list
The system SHALL advertise the existing seven assistant functions as MCP tools through the `tools/list` JSON-RPC method.

#### Scenario: Client requests tool list
- **WHEN** an authenticated client sends a `tools/list` JSON-RPC request
- **THEN** the response contains tools named `get_accounts`, `get_transactions`, `get_holdings`, `get_balance_sheet`, `get_income_statement`, `import_bank_statement`, and `search_family_files`

#### Scenario: Each tool has a valid input schema
- **WHEN** the client receives the tool list
- **THEN** every tool has a non-empty `description` and an `inputSchema` of type `object`

### Requirement: Server executes financial tools via tools/call
The system SHALL invoke the corresponding `Assistant::Function` when a client calls `tools/call` with a valid tool name and arguments.

#### Scenario: Calling get_balance_sheet
- **WHEN** an authenticated client calls `tools/call` with name `get_balance_sheet` and empty arguments
- **THEN** the server returns a text content response containing the user's balance sheet data as JSON

#### Scenario: Calling get_transactions with filters
- **WHEN** an authenticated client calls `tools/call` with name `get_transactions` and valid filter arguments
- **THEN** the server returns a paginated list of matching transactions as JSON

#### Scenario: Unknown tool name
- **WHEN** an authenticated client calls `tools/call` with a tool name not in the tool list
- **THEN** the server returns a JSON-RPC error indicating the tool is unknown

### Requirement: Server acts on behalf of the configured MCP user
The system SHALL resolve the user identified by `MCP_USER_EMAIL` and set `Current.session` to a fresh session for that user before executing any tool.

#### Scenario: Tool execution uses configured user
- **WHEN** a tool is executed through `/mcp/fast`
- **THEN** the tool operates on the accounts and data accessible to the `MCP_USER_EMAIL` user

#### Scenario: Missing configured user
- **WHEN** `MCP_USER_EMAIL` is unset or does not match any user
- **THEN** the server responds with HTTP 503 Service Unavailable and an appropriate error message

### Requirement: Existing MCP controller remains functional
The system SHALL continue to serve the existing `POST /mcp` endpoint without behavior changes.

#### Scenario: Legacy endpoint still works
- **WHEN** an authenticated client posts a valid JSON-RPC request to `POST /mcp`
- **THEN** the legacy `McpController` handles the request as before

### Requirement: Configuration is documented
The system SHALL document the required environment variables and a sample client configuration.

#### Scenario: Environment variables documented
- **WHEN** a developer reads `.env.local.example`
- **THEN** `MCP_API_TOKEN` and `MCP_USER_EMAIL` are documented with descriptions

#### Scenario: Client configuration documented
- **WHEN** a developer reads `AGENTS.md`
- **THEN** the SSE endpoint URL and a Claude Desktop configuration example are present

