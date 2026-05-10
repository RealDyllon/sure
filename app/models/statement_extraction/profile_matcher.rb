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

        if profile
          next account_payload.merge(
            "statement_profile_id" => profile.id,
            "matched_account_id" => profile.account_id,
            "review" => review_for(profile.account, account_type: profile.account_type, account_subtype: profile.account_subtype, currency: profile.currency)
          )
        end

        matched_account = heuristic_account_match(account_payload)
        next account_payload unless matched_account

        account_payload.merge(
          "matched_account_id" => matched_account.id,
          "review" => review_for(
            matched_account,
            account_type: matched_account.accountable_type,
            account_subtype: account_payload["subtype"].presence || matched_account.subtype,
            currency: matched_account.currency
          )
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

    private

      def review_for(account, account_type:, account_subtype:, currency:)
        {
          "action" => "match",
          "account_id" => account.id,
          "account_type" => account_type,
          "account_subtype" => account_subtype,
          "account_name" => account.name,
          "currency" => currency
        }
      end

      def heuristic_account_match(account_payload)
        source_suffix = account_payload["source_id"].to_s.split(":").last

        candidates = family.accounts.visible_manual.select do |account|
          compatible_account?(account, account_payload) &&
            heuristic_name_match?(account, account_payload, source_suffix)
        end

        candidates.one? ? candidates.first : nil
      end

      def compatible_account?(account, account_payload)
        return false if account_payload["currency"].present? && account.currency != account_payload["currency"]
        return false if account_payload["account_type"].present? && account.accountable_type != account_payload["account_type"]
        return false if account_payload["subtype"].present? && account.subtype.present? && account.subtype != account_payload["subtype"]

        true
      end

      def heuristic_name_match?(account, account_payload, source_suffix)
        account_name = account.name.to_s.downcase
        extracted_name = account_payload["name"].to_s.downcase
        provider_name = result.provider.to_s.downcase

        return true if normalized_account_name(account.name) == normalized_account_name(account_payload["name"])

        return false if source_suffix.blank? || source_suffix == "default"

        account_name.include?(source_suffix) &&
          (account_name.include?(provider_name) || extracted_name.include?(provider_name))
      end

      def normalized_account_name(name)
        name.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
      end
  end
end
