# frozen_string_literal: true

# Provider::LlmHealth::LlmErrorSanitizer strips secrets and oversized payloads
# from a raw provider error string so the resulting technical message is safe
# to persist on a chat (Chat#error) and show in admin/debug surfaces.
#
# It removes:
# - API keys, bearer tokens, OAuth tokens, Codex auth file contents
# - Common secret-bearing substrings ("sk-...", "Bearer ...")
# - Stack traces and Ruby file paths
# - Newlines beyond a single sanitized line
# - Oversized messages (capped and truncated with an ellipsis)
#
# It keeps short, useful technical context (HTTP status codes, provider
# messages like "401 Unauthorized") because that is exactly what an admin
# needs to fix a misconfigured provider.
module Provider::LlmHealth::LlmErrorSanitizer
  MAX_LENGTH = 1_000

  SECRET_TOKEN_PATTERN = %r{
    sk-[A-Za-z0-9_-]{6,}                       |   # OpenAI-style API keys
    Bearer\s+[A-Za-z0-9._-]{6,}                |   # Bearer tokens
    (?:access_token|api[_-]?key|token) [=:] \s* ["']? [A-Za-z0-9._-]{6,} ["']?
  }xi.freeze

  STACK_TRACE_PREDICATE = ->(line) do
    stripped = line.strip
    # Only treat a line as a stack-trace fragment when it STARTS with a
    # backtrace shape, so we don't discard a single-line error message that
    # merely mentions a file path.
    return true if stripped.match?(/\A(?:\w+::)*\w+\.\w+:\d+:/)
    return true if stripped.match?(/\Afrom\b.*:\d+:in\b/)
    return true if stripped.match?(/\Abacktrace:/i)

    false
  end

  FILE_PATH_PATTERN = %r{
    /(?:Users|home|var|etc|tmp|app|lib|usr)/ [^\s'"]+
    (?: :\d+ (?: :in \s+ [`'] [^'`]+ [`'] )? )?
  }x.freeze

  SECRET_LABEL_PATTERN = /
    (password|passwd|secret|api[_-]?key|access[_-]?token|oauth[_-]?token)
    \s* [:=] \s*
  /xi.freeze

  class << self
    def sanitize(message)
      return "" if message.blank?

      sanitized = message.to_s
      sanitized = strip_secrets(sanitized)
      sanitized = strip_stack_traces(sanitized)
      sanitized = strip_file_paths(sanitized)
      sanitized = collapse_to_single_line(sanitized)
      sanitized = strip_secret_labels(sanitized)
      truncate(sanitized)
    end

    private

      def strip_secrets(text)
        text.gsub(SECRET_TOKEN_PATTERN, "[REDACTED]")
      end

      def strip_secret_labels(text)
        text.gsub(SECRET_LABEL_PATTERN, '\1=[REDACTED]')
      end

      def strip_stack_traces(text)
        text.split("\n").reject { |line| STACK_TRACE_PREDICATE.call(line) }.join(" ")
      end

      def strip_file_paths(text)
        text.gsub(FILE_PATH_PATTERN, "[path]")
      end

      def collapse_to_single_line(text)
        text.gsub(/\s+/, " ").strip
      end

      def truncate(text)
        return text if text.length <= MAX_LENGTH

        text[0, MAX_LENGTH] + "…"
      end
  end
end