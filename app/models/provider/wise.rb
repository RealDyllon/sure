class Provider::Wise
  include HTTParty
  extend SslConfigurable

  DEFAULT_BASE_URL = "https://api.wise.com"
  DEFAULT_AUTH_URL = "https://wise.com"

  headers "User-Agent" => "Sure Finance Wise Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :access_token, :refresh_token, :base_url, :auth_url, :client_id, :client_secret

  def self.oauth_client_id
    ENV["WISE_CLIENT_ID"].presence || Setting["wise_client_id"].presence
  end

  def self.oauth_client_secret
    ENV["WISE_CLIENT_SECRET"].presence || Setting["wise_client_secret"].presence
  end

  def self.oauth_redirect_uri
    ENV["WISE_REDIRECT_URI"].presence || Setting["wise_redirect_uri"].presence
  end

  def self.oauth_auth_url
    ENV["WISE_AUTH_URL"].presence || Setting["wise_auth_url"].presence || DEFAULT_AUTH_URL
  end

  def self.oauth_base_url
    ENV["WISE_BASE_URL"].presence || Setting["wise_base_url"].presence || DEFAULT_BASE_URL
  end

  def self.oauth_configured?
    oauth_client_id.present? && oauth_client_secret.present?
  end

  def self.oauth_authorize_url(redirect_uri:, state:)
    query = {
      response_type: "code",
      client_id: oauth_client_id,
      redirect_uri: redirect_uri,
      state: state
    }

    "#{oauth_auth_url}/oauth/authorize?#{URI.encode_www_form(query)}"
  end

  def initialize(access_token:, refresh_token: nil, base_url: DEFAULT_BASE_URL, auth_url: DEFAULT_AUTH_URL, client_id: nil, client_secret: nil)
    @access_token = access_token
    @refresh_token = refresh_token
    @base_url = base_url.presence || DEFAULT_BASE_URL
    @auth_url = auth_url.presence || DEFAULT_AUTH_URL
    @client_id = client_id
    @client_secret = client_secret
  end

  def exchange_code_for_token(code:, redirect_uri:)
    token_request(
      {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: client_id
      }
    )
  end

  def refresh_access_token
    raise WiseError.new("Wise refresh token is missing", :unauthorized) if refresh_token.blank?

    token_request(
      {
        grant_type: "refresh_token",
        refresh_token: refresh_token
      }
    )
  end

  def get_profiles
    get("/v1/profiles")
  end

  def get_balances(profile_id:)
    get("/v4/profiles/#{url_escape(profile_id)}/balances", query: { types: "STANDARD" })
  end

  def get_cards(profile_id:)
    get("/v3/spend/profiles/#{url_escape(profile_id)}/cards")
  end

  def get_balance_statement(profile_id:, balance_id:, currency:, interval_start:, interval_end:)
    get(
      "/v1/profiles/#{url_escape(profile_id)}/balance-statements/#{url_escape(balance_id)}/statement.json",
      query: {
        currency: currency,
        intervalStart: interval_start,
        intervalEnd: interval_end,
        type: "COMPACT"
      }
    )
  end

  def create_quote(profile_id:, source_currency:, target_currency:, target_amount: nil, source_amount: nil)
    body = {
      sourceCurrency: source_currency,
      targetCurrency: target_currency,
      profile: profile_id
    }
    body[:targetAmount] = target_amount if target_amount.present?
    body[:sourceAmount] = source_amount if source_amount.present?

    post("/v3/profiles/#{url_escape(profile_id)}/quotes", body: body)
  end

  private

    def get(path, query: {})
      response = self.class.get("#{base_url}#{path}", headers: auth_headers, query: query.compact)
      handle_response(response)
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise WiseError.new("Wise request failed: #{e.message}", :request_failed)
    end

    def post(path, body: {})
      response = self.class.post(
        "#{base_url}#{path}",
        headers: auth_headers.merge("Content-Type" => "application/json"),
        body: body.compact.to_json
      )
      handle_response(response)
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise WiseError.new("Wise request failed: #{e.message}", :request_failed)
    end

    def token_request(body)
      options = { body: body.compact }
      if client_id.present? && client_secret.present?
        options[:basic_auth] = { username: client_id, password: client_secret }
      end

      response = self.class.post(
        "#{base_url}/oauth/token",
        options
      )
      handle_response(response)
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise WiseError.new("Wise request failed: #{e.message}", :request_failed)
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{access_token}",
        "Accept" => "application/json"
      }
    end

    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body.presence || "{}", symbolize_names: true)
      when 400
        raise WiseError.new(parse_error_message(response.body, default: "Bad request to Wise API"), :bad_request)
      when 401
        raise WiseError.new(parse_error_message(response.body, default: "Wise authorization failed. The token may be expired or revoked."), :unauthorized)
      when 403
        raise WiseError.new(parse_error_message(response.body, default: "Wise access forbidden. The token may lack the required scopes."), :access_forbidden)
      when 404
        raise WiseError.new("Wise resource not found", :not_found)
      when 429
        raise WiseError.new("Wise rate limit exceeded. Please try again later.", :rate_limited)
      else
        raise WiseError.new("Wise API error: #{response.code} #{response.body}", :api_error)
      end
    rescue JSON::ParserError => e
      raise WiseError.new("Invalid Wise response: #{e.message}", :invalid_response)
    end

    # Best-effort: pull a human-readable error message out of the response
    # body. Wise's error format is not strongly typed, so we look for a
    # handful of known keys before falling back to the raw body.
    def parse_error_message(body, default:)
      parsed = JSON.parse(body.to_s, symbolize_names: true)
      message = parsed[:error] || parsed[:message] || parsed[:error_description]
      return message if message.is_a?(String) && message.present?

      # Wise occasionally returns errors as a list under `errors`.
      first = Array(parsed[:errors]).first
      if first.is_a?(Hash) && first[:message].present?
        return first[:message]
      end

      default
    rescue JSON::ParserError
      default
    end

    def url_escape(value)
      ERB::Util.url_encode(value.to_s)
    end

    class WiseError < StandardError
      attr_reader :error_type

      def initialize(message, error_type = :unknown)
        super(message)
        @error_type = error_type
      end
    end
end
