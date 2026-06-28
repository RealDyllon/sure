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

  # fast-mcp's `Server#send_formatted_result` only passes through results that
  # are a Hash with a `:content` key; anything else is coerced with `to_s` and
  # marked `isError: false`. We therefore return MCP-spec-compliant content
  # envelopes so clients receive JSON text and errors are flagged correctly.
  #
  # Unexpected exceptions are NOT rescued here — they propagate to
  # `FastMcp::Server#handle_tools_call`, which logs them and returns a proper
  # `isError: true` result.
  def call(**kwargs)
    klass = self.class.function_class
    ActiveSupport::CurrentAttributes.clear_all

    return not_configured_error unless mcp_user_configured?

    setup_mcp_session!

    data = klass.new(current_user).call(stringify_args(kwargs))
    mcp_content(data.as_json.to_json)
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
      mcp_content(
        { "error" => "mcp_user_not_configured",
          "message" => "Set the MCP_USER_EMAIL environment variable to a valid user email." }.to_json,
        is_error: true
      )
    end

    # Build an MCP-spec tool result envelope. `text` is the JSON string the
    # client receives as text content; `is_error` flags the result per spec.
    def mcp_content(text, is_error: false)
      {
        content: [ { type: "text", text: text } ],
        isError: is_error
      }
    end
end
