module StatementExtraction
  class Result
    attr_reader :provider, :file_type, :statement_period, :accounts, :confidence, :errors

    def initialize(provider:, file_type:, statement_period: {}, accounts: [], confidence: 1.0, errors: [])
      @provider = provider.to_s
      @file_type = file_type.to_s
      @statement_period = stringify_hash(statement_period || {})
      @accounts = Array(accounts).map { |account| stringify_hash(account) }
      @confidence = confidence.to_f
      @errors = Array(errors)
    end

    def to_h
      {
        "provider" => provider,
        "file_type" => file_type,
        "statement_period" => statement_period,
        "accounts" => accounts,
        "confidence" => confidence,
        "errors" => errors
      }
    end

    private

      def stringify_hash(value)
        value.to_h.deep_stringify_keys
      end
  end
end
