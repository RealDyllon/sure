require "base64"
require "fileutils"
require "json"
require "net/http"
require "uri"

class Provider::OpenaiViaCodex::Auth
  Error = Class.new(Provider::OpenaiViaCodex::Error)

  REFRESH_URL = "https://auth.openai.com/oauth/token".freeze
  CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann".freeze
  REFRESH_SKEW_SECONDS = 30
  REFRESH_MUTEX = Mutex.new

  def initialize(path: nil, now: -> { Time.current.to_i })
    @path = path
    @now = now
    @mutex = REFRESH_MUTEX
  end

  def access_token_and_account_id
    mutex.synchronize do
      data = read_auth
      tokens = data["tokens"] || {}
      access_token = tokens["access_token"]

      if access_token.blank?
        raise Error, "No ChatGPT tokens found in auth.json. Run `codex login` first."
      end

      return [ access_token, tokens["account_id"] ] unless refresh_required?(access_token)

      refresh_token = tokens["refresh_token"]
      if refresh_token.blank?
        raise Error, "No refresh token available. Run `codex login` to re-authenticate."
      end

      new_tokens = refresh_tokens(refresh_token)
      tokens["access_token"] = new_tokens["access_token"] if new_tokens["access_token"].present?
      tokens["id_token"] = new_tokens["id_token"] if new_tokens["id_token"].present?
      tokens["refresh_token"] = new_tokens["refresh_token"] if new_tokens["refresh_token"].present?
      data["tokens"] = tokens
      data["last_refresh"] = Time.current.utc.iso8601
      write_auth(data)

      [ tokens["access_token"], tokens["account_id"] ]
    end
  end

  def configured?
    data = read_auth
    data["auth_mode"] == "chatgpt" && data.dig("tokens", "access_token").present?
  rescue Error
    false
  end

  def auth_path
    @auth_path ||= begin
      candidate = @path.presence ||
        ENV["CODEX_AUTH_PATH"].presence ||
        File.join(ENV["CODEX_HOME"].presence || File.expand_path("~/.codex"), "auth.json")

      unless File.exist?(candidate)
        raise Error, "Codex auth file not found at #{candidate}. Run `codex login` first."
      end

      candidate
    end
  end

  protected

    def refresh_tokens(refresh_token)
      uri = URI(REFRESH_URL)
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request.body = {
        client_id: CLIENT_ID,
        grant_type: "refresh_token",
        refresh_token: refresh_token
      }.to_json

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end

      parsed = parse_json(response.body)
      return parsed if response.is_a?(Net::HTTPSuccess)

      error_code = parsed["error"]
      if %w[refresh_token_expired refresh_token_reused refresh_token_invalidated].include?(error_code)
        raise Error, "Refresh token is no longer valid (#{error_code}). Run `codex login` to re-authenticate."
      end

      raise Error, "Token refresh failed (HTTP #{response.code}): #{response.body}"
    rescue JSON::ParserError
      raise Error, "Token refresh failed (HTTP #{response&.code}): #{response&.body}"
    rescue SocketError, SystemCallError, Timeout::Error => e
      raise Error, "Token refresh failed (network error): #{e.message}"
    end

  private

    attr_reader :mutex, :now

    def read_auth
      data = parse_json(File.read(auth_path))
      unless data["auth_mode"] == "chatgpt"
        raise Error, "Expected auth_mode 'chatgpt', got '#{data["auth_mode"]}'. This provider only supports ChatGPT OAuth tokens."
      end

      data
    rescue Errno::ENOENT
      missing_path = @auth_path || @path || ENV["CODEX_AUTH_PATH"] || File.join(ENV["CODEX_HOME"].presence || File.expand_path("~/.codex"), "auth.json")
      @auth_path = nil
      raise Error, "Codex auth file not found at #{missing_path}. Run `codex login` first."
    end

    def write_auth(data)
      tmp_path = "#{auth_path}.tmp"
      File.write(tmp_path, JSON.pretty_generate(data))
      FileUtils.mv(tmp_path, auth_path)
      File.chmod(0o600, auth_path)
    ensure
      FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
    end

    def refresh_required?(access_token)
      exp = jwt_exp(access_token)
      return false if exp.nil?

      now.call >= (exp - REFRESH_SKEW_SECONDS)
    end

    def jwt_exp(token)
      payload = token.to_s.split(".")[1]
      return nil if payload.blank?

      payload += "=" * ((4 - payload.length % 4) % 4)
      parse_json(Base64.urlsafe_decode64(payload))["exp"]
    rescue ArgumentError, JSON::ParserError
      nil
    end

    def parse_json(value)
      JSON.parse(value)
    end
end
