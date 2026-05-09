require "json"
require "net/http"
require "uri"
require "cgi"

class Provider::OpenaiViaCodex::Client
  Error = Class.new(Provider::OpenaiViaCodex::Error)

  attr_reader :auth, :base_url, :client_version

  def initialize(auth:, base_url: Provider::OpenaiViaCodex::CODEX_BASE_URL, client_version: "1.0.0")
    @auth = auth
    @base_url = base_url
    @client_version = client_version
  end

  def responses
    @responses ||= Responses.new(self)
  end

  def chat(parameters:)
    response = nil
    output_text = +""
    stream = proc do |event|
      case event["type"]
      when "response.output_text.delta", "response.refusal.delta"
        output_text << event["delta"].to_s
      when "response.completed"
        response = event["response"]
      end
    end

    responses.create(parameters: chat_to_responses_parameters(parameters).merge(stream: stream))
    raise Error, "Codex API stream completed without a response" if response.blank?
    content = extract_output_text(response).presence || output_text

    {
      "id" => response["id"],
      "model" => response["model"],
      "choices" => [
        {
          "message" => {
            "role" => "assistant",
            "content" => content,
            "tool_calls" => extract_tool_calls(response)
          }.compact
        }
      ],
      "usage" => response["usage"]
    }
  end

  def fetch_model_slugs
    Rails.cache.fetch("openai_via_codex:model_slugs", expires_in: 1.hour) do
      response = request_json(:get, "/models?client_version=#{CGI.escape(client_version)}")
      models = Array(response["models"]).filter_map do |model|
        next unless model["supported_in_api"] && model["visibility"] == "list"

        model["slug"]
      end

      models.presence || Provider::OpenaiViaCodex::DEFAULT_MODEL_SLUGS
    end
  rescue Error
    Provider::OpenaiViaCodex::DEFAULT_MODEL_SLUGS
  end

  def request_json(method, path, body: nil, stream: nil)
    uri = URI.join("#{base_url}/", path.delete_prefix("/"))
    request = build_request(method, uri, body)

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      if stream
        http.request(request) do |response|
          handle_stream_response(response, stream)
          return nil
        end
      end

      response = http.request(request)
      response_body = response.body.to_s
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "Codex API returned HTTP #{response.code}: #{response_body}"
      end

      return parse_json(response_body)
    end
  rescue JSON::ParserError => e
    raise Error, "Codex API returned invalid JSON: #{e.message}"
  rescue SocketError, SystemCallError, Timeout::Error => e
    raise Error, "Codex API request failed: #{e.message}"
  end

  private

    def build_request(method, uri, body)
      access_token, account_id = auth.access_token_and_account_id
      request = method.to_sym == :get ? Net::HTTP::Get.new(uri.request_uri) : Net::HTTP::Post.new(uri.request_uri)
      request["Authorization"] = "Bearer #{access_token}"
      request["ChatGPT-Account-ID"] = account_id if account_id.present?
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream, application/json"
      request.body = body.to_json if body
      request
    end

    def handle_stream_response(response, stream)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "Codex API returned HTTP #{response.code}: #{response.body}"
      end

      buffer = +""
      response.read_body do |chunk|
        buffer << chunk

        while (line_end = buffer.index("\n"))
          line = buffer.slice!(0..line_end).strip
          next if line.blank? || !line.start_with?("data:")

          data = line.delete_prefix("data:").delete_prefix(" ")
          return if data == "[DONE]"

          stream.call(parse_json(data))
        end
      end
    end

    def chat_to_responses_parameters(parameters)
      messages = Array(parameters[:messages] || parameters["messages"])
      instructions = messages.select { |message| %w[system developer].include?(message[:role] || message["role"]) }
                             .map { |message| message[:content] || message["content"] }
                             .join("\n\n")
                             .presence

      input = messages.reject { |message| %w[system developer].include?(message[:role] || message["role"]) }
                      .flat_map { |message| chat_message_to_response_input(message) }
      response_format = parameters[:response_format] || parameters["response_format"]
      ensure_json_mode_input!(input, response_format)

      {
        model: parameters[:model] || parameters["model"],
        input: input,
        instructions: instructions,
        max_output_tokens: parameters[:max_tokens] || parameters["max_tokens"],
        text: response_text_format(response_format),
        tools: response_tools(parameters[:tools] || parameters["tools"]),
        store: false
      }.compact
    end

    def ensure_json_mode_input!(input, response_format)
      type = response_format&.dig(:type) || response_format&.dig("type")
      return unless type == "json_object"
      return if input.any? { |item| response_input_contains_json?(item) }

      message = input.reverse.find { |item| item[:role] == "user" || item["role"] == "user" }
      if message
        append_json_instruction!(message)
      else
        input << { role: "user", content: "Return JSON." }
      end
    end

    def response_input_contains_json?(item)
      content = item[:content] || item["content"]
      content_text(content).match?(/json/i)
    end

    def content_text(content)
      return content.to_s if content.is_a?(String)

      Array(content).map do |part|
        part[:text] || part["text"]
      end.compact.join("\n")
    end

    def append_json_instruction!(message)
      content = message[:content] || message["content"]

      if content.is_a?(String)
        message[:content] = "#{content}\n\nReturn JSON."
      else
        message[:content] = Array(content) + [ { type: "input_text", text: "Return JSON." } ]
      end
    end

    def chat_message_to_response_input(message)
      role = (message[:role] || message["role"]).to_s
      return tool_message_to_response_input(message) if role == "tool"
      return assistant_tool_calls_to_response_input(message) if role == "assistant" && (message[:tool_calls] || message["tool_calls"]).present?

      role = "user" unless role == "assistant"

      {
        role: role,
        content: chat_content_to_response_content(message[:content] || message["content"])
      }
    end

    def tool_message_to_response_input(message)
      {
        type: "function_call_output",
        call_id: message[:tool_call_id] || message["tool_call_id"],
        output: message[:content] || message["content"] || ""
      }
    end

    def assistant_tool_calls_to_response_input(message)
      Array(message[:tool_calls] || message["tool_calls"]).map do |tool_call|
        function = tool_call[:function] || tool_call["function"] || {}

        {
          type: "function_call",
          call_id: tool_call[:id] || tool_call["id"],
          name: function[:name] || function["name"],
          arguments: function[:arguments] || function["arguments"] || "{}"
        }
      end
    end

    def chat_content_to_response_content(content)
      return content if content.is_a?(String)

      Array(content).map do |item|
        type = item[:type] || item["type"]
        case type
        when "text"
          { type: "input_text", text: item[:text] || item["text"] }
        when "image_url"
          image_url = item[:image_url] || item["image_url"] || {}
          { type: "input_image", image_url: image_url[:url] || image_url["url"], detail: image_url[:detail] || image_url["detail"] || "low" }
        else
          item
        end
      end
    end

    def response_text_format(response_format)
      return nil if response_format.blank?

      type = response_format[:type] || response_format["type"]
      case type
      when "json_object"
        { format: { type: "json_object" } }
      when "json_schema"
        json_schema = response_format[:json_schema] || response_format["json_schema"] || {}
        {
          format: {
            type: "json_schema",
            name: json_schema[:name] || json_schema["name"] || "output",
            strict: json_schema.key?(:strict) ? json_schema[:strict] : json_schema["strict"],
            schema: json_schema[:schema] || json_schema["schema"]
          }.compact
        }
      end
    end

    def response_tools(tools)
      Array(tools).map do |tool|
        function = tool[:function] || tool["function"]
        next tool if function.blank?

        {
          type: "function",
          name: function[:name] || function["name"],
          description: function[:description] || function["description"],
          parameters: function[:parameters] || function["parameters"],
          strict: function.key?(:strict) ? function[:strict] : function["strict"]
        }.compact
      end.compact.presence
    end

    def extract_output_text(response)
      Array(response["output"]).filter_map do |item|
        next unless item["type"] == "message"

        Array(item["content"]).map { |content| content["text"] || content["refusal"] }.compact.join("\n")
      end.join("\n")
    end

    def extract_tool_calls(response)
      Array(response["output"]).filter_map do |item|
        next unless item["type"] == "function_call"

        {
          "id" => item["call_id"] || item["id"],
          "type" => "function",
          "function" => {
            "name" => item["name"],
            "arguments" => item["arguments"] || "{}"
          }
        }
      end
    end

    def parse_json(value)
      JSON.parse(value)
    end

  class Responses
    def initialize(client)
      @client = client
    end

    def create(parameters:)
      params = normalize_parameters(parameters)
      stream = params.delete(:stream)
      params[:model] = strip_model_prefix(params[:model])
      params[:store] = false unless params.key?(:store)

      if stream.respond_to?(:call)
        @client.request_json(:post, "/responses", body: params.merge(stream: true), stream: stream)
      else
        @client.request_json(:post, "/responses", body: params)
      end
    end

    private

      def normalize_parameters(parameters)
        parameters.to_h.deep_symbolize_keys.except(:previous_response_id).compact
      end

      def strip_model_prefix(model)
        model.to_s.delete_prefix(Provider::OpenaiViaCodex::MODEL_PREFIX)
      end
  end
end
