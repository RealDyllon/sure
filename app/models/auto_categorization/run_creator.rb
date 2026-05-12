module AutoCategorization
  class RunCreator
    MissingProviderError = Class.new(StandardError)

    def self.call(family:, user:)
      new(family:, user:).call
    end

    def initialize(family:, user:)
      @family = family
      @user = user
    end

    def call
      provider = Provider::Registry.default_llm_provider
      raise MissingProviderError, "AI configuration is required" unless provider

      run = AutoCategorizationRun.create!(
        family: family,
        user: user,
        status: :draft,
        provider_name: provider.provider_name,
        model: Provider::Registry.default_llm_model,
        started_at: Time.current
      )

      snapshot_entries!(run)

      if run.run_transactions.none?
        run.update!(status: :empty, finished_at: Time.current)
        run.finish_processing_progress!(message: "No eligible uncategorized transactions")
      else
        run.queue_generation!
      end

      run
    end

    private
      attr_reader :family, :user

      def snapshot_entries!(run)
        captured_at = Time.current

        AutoCategorization::EligibilityQuery.new(family:, user:).entries.find_each do |entry|
          transaction = entry.entryable
          run.run_transactions.create!(
            entry: entry,
            live_transaction: transaction,
            account: entry.account,
            captured_at: captured_at,
            snapshot: snapshot_for(entry, transaction)
          )
        end
      end

      def snapshot_for(entry, transaction)
        {
          "date" => entry.date&.iso8601,
          "name" => entry.name,
          "description" => [ entry.name, entry.notes ].compact_blank.join(" "),
          "notes" => entry.notes,
          "amount" => entry.amount.abs.to_s,
          "currency" => entry.currency,
          "classification" => entry.classification,
          "merchant" => transaction.merchant&.name,
          "transaction_kind" => transaction.kind
        }.compact
      end
  end
end
