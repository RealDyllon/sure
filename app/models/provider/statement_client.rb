class Provider::StatementClient
  def initialize(provider:, family:)
    @provider = provider
    @family = family
  end

  def chat(parameters:)
    messages = parameters.fetch(:messages)
    instructions = messages.select { |message| message[:role] == "system" }.map { |message| message[:content] }.join("\n")
    prompt = messages.reject { |message| message[:role] == "system" }.map { |message| message[:content] }.join("\n")
    response = @provider.chat_response(prompt, instructions: instructions, model: parameters.fetch(:model), family: @family)
    raise Provider::Error, "Statement AI request failed" unless response.success?

    { "choices" => [ { "message" => { "content" => response.data.messages.map(&:output_text).join("\n") } } ] }
  end
end
