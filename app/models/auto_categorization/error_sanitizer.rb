module AutoCategorization
  class ErrorSanitizer
    MAX_LENGTH = 500
    PROVIDER_FAILURE_MESSAGE = "AI provider failed while processing suggestions. Try again.".freeze

    def self.call(error)
      new(error).call
    end

    def initialize(error)
      @error = error
    end

    def call
      return PROVIDER_FAILURE_MESSAGE if provider_error?

      message = if error.respond_to?(:message)
        error.message
      else
        error.to_s
      end

      message.to_s.squish.presence&.truncate(MAX_LENGTH) || "AI categorization failed."
    end

    private
      attr_reader :error

      def provider_error?
        error.is_a?(Provider::Error) || error.class.name.to_s.start_with?("Provider::")
      end
  end
end
