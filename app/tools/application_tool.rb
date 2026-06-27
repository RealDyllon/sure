# frozen_string_literal: true

# Base class for all fast-mcp tools in this application.
#
# Tools in `app/tools/` that inherit from `ApplicationTool` are automatically
# picked up by the `FastMcp.mount_in_rails` initializer (registered via
# `ApplicationTool.descendants` in `config.after_initialize`).
#
# The base class:
#   * Resolves the acting user from `ENV["MCP_USER_EMAIL"]`.
#   * Builds a fresh `Session` and assigns it to `Current.session` for the
#     duration of the tool call, mirroring `McpController#setup_mcp_user`.
#   * Resets `Current` attributes after the call so requests don't leak state
#     between tool invocations.
#
# Subclasses must implement `function_class` to return the existing
# `Assistant::Function` class they wrap. They may override `input_arguments` to
# declare Dry::Schema arguments or rely on the function's existing schema.
class ApplicationTool < ActionTool::Base
  class << self
    # Returns the `Assistant::Function` subclass that this tool wraps. The
    # value of the tool's `name` is delegated to the wrapped function so the
    # MCP tool name matches the chat-tool name 1:1.
    def function_class
      raise NotImplementedError, "Subclasses must implement .function_class"
    end

    def tool_name
      function_class.name
    end
  end

  def call(**kwargs)
    klass = self.class.function_class
    ActiveSupport::CurrentAttributes.clear_all

    unless mcp_user_configured?
      return not_configured_error
    end

    setup_mcp_session!

    klass.new(current_user).call(stringify_args(kwargs)).as_json
  rescue StandardError => e
    Rails.logger.error("[MCP Tool #{self.class.tool_name}] #{e.class.name}: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
    { "error" => e.message, "type" => e.class.name }
  ensure
    ActiveSupport::CurrentAttributes.clear_all
  end

  private

    # The acting user is the one configured via `MCP_USER_EMAIL`. This is the
    # same convention used by the legacy `McpController`.
    def current_user
      @current_user ||= User.find_by(email: ENV.fetch("MCP_USER_EMAIL", ""))
    end

    def mcp_user_configured?
      ENV["MCP_USER_EMAIL"].present? && current_user.present?
    end

    # Build a fresh in-memory session for the MCP user. The session is never
    # persisted (matching the legacy controller behavior) so we don't accumulate
    # Session rows on every MCP request.
    def setup_mcp_session!
      return unless mcp_user_configured?

      Current.session = current_user.sessions.build(
        user_agent: "fast-mcp",
        ip_address: nil
      )
    end

    # Convert keyword arguments into a string-keyed hash so we can forward the
    # payload to the existing `Assistant::Function#call` API.
    def stringify_args(kwargs)
      kwargs.transform_keys(&:to_s)
    end

    def not_configured_error
      {
        "error" => "mcp_user_not_configured",
        "message" => "Set the MCP_USER_EMAIL environment variable to a valid user email."
      }
    end
end
