module StatementExtraction
  class ProfileMatcher
    attr_reader :family, :result

    def initialize(family:, result:)
      @family = family
      @result = result
    end

    def call
      matched_accounts = result.accounts.map do |account_payload|
        profile = family.statement_profiles.find_by(
          provider: result.provider,
          source_id: account_payload["source_id"]
        )

        next account_payload unless profile

        account_payload.merge(
          "statement_profile_id" => profile.id,
          "matched_account_id" => profile.account_id,
          "review" => {
            "action" => "match",
            "account_id" => profile.account_id,
            "account_type" => profile.account_type,
            "account_subtype" => profile.account_subtype,
            "account_name" => profile.account.name,
            "currency" => profile.currency
          }
        )
      end

      Result.new(
        provider: result.provider,
        file_type: result.file_type,
        statement_period: result.statement_period,
        accounts: matched_accounts,
        confidence: result.confidence,
        errors: result.errors
      )
    end
  end
end
