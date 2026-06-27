# frozen_string_literal: true

# Fast MCP server mount.
#
# Exposes a Model Context Protocol (MCP) endpoint at /mcp/fast alongside the
# legacy hand-rolled /mcp JSON-RPC controller. Authentication uses
# `MCP_API_TOKEN` (the same env var as the legacy controller) and the resolved
# acting user comes from `MCP_USER_EMAIL`. When either env var is missing the
# middleware is not mounted so we never accidentally expose the endpoint
# unauthenticated.
#
# We bypass `FastMcp.mount_in_rails` and use `app.middleware.use` directly so
# we can install an `EnvAwareAuthenticatedRackTransport` that re-reads the
# bearer token from the environment on every request (mirroring the legacy
# `McpController#authenticate_mcp_token!` behavior).
return unless ENV["MCP_API_TOKEN"].present? && ENV["MCP_USER_EMAIL"].present?

require "fast_mcp"
require Rails.root.join("lib/fast_mcp/transports/env_aware_authenticated_rack_transport")

server = FastMcp::Server.new(
  name: Rails.application.class.module_parent_name.underscore.dasherize,
  version: "1.0.0",
  logger: Rails.logger
)
server.transport_klass = FastMcp::Transports::EnvAwareAuthenticatedRackTransport

# Tool registration must happen after Zeitwerk is fully running, which is in
# the finisher hook (after all `:load_config_initializers` initializers have
# run). We pre-require the tool files so `ApplicationTool.descendants` is
# fully populated.
Rails.application.config.after_initialize do
  Dir[Rails.root.join("app", "tools", "**", "*.rb")].each { |f| require f }
  server.register_tools(*ApplicationTool.descendants)
end

allowed_origins = FastMcp.default_rails_allowed_origins(Rails.application) + %w[localhost 127.0.0.1 [::1]]
# The default host for Rails integration tests (`ActionDispatch::IntegrationTest`).
allowed_origins << "www.example.com" if Rails.env.test?

Rails.application.middleware.use(
  FastMcp::Transports::EnvAwareAuthenticatedRackTransport,
  server,
  path_prefix: "/mcp/fast",
  messages_route: "messages",
  sse_route: "sse",
  auth_token: ENV.fetch("MCP_API_TOKEN"),
  auth_header_name: "Authorization",
  allowed_origins: allowed_origins,
  # In development the request IP is 127.0.0.1, but tools that talk to the
  # server (e.g. a local Claude Desktop) may arrive from other local IPs on
  # shared networks. Allow all in development, restrict in production.
  localhost_only: !Rails.env.local?,
  logger: Rails.logger
)
