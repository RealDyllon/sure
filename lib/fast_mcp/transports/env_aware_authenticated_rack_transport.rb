# frozen_string_literal: true

module FastMcp
  module Transports
    # Like `FastMcp::Transports::AuthenticatedRackTransport`, but re-reads
    # `MCP_API_TOKEN` from the environment on every request. This matches the
    # dynamic behavior of the legacy hand-rolled `McpController` and lets tests
    # use `with_env_overrides` to rotate the token without restarting the
    # server.
    class EnvAwareAuthenticatedRackTransport < AuthenticatedRackTransport
      def valid_token?(token)
        token.to_s == ENV["MCP_API_TOKEN"].to_s
      end
    end
  end
end
