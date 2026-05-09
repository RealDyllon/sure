module StatementExtraction
  class Publisher
    attr_reader :statement_import

    def initialize(statement_import)
      @statement_import = statement_import
    end

    def publish!
      raise Import::MappingError, "Statement import requires account review before publishing" unless statement_import.review_complete?

      Import.transaction do
        statement_import.extracted_accounts.each do |account_payload|
          account = account_for(account_payload)
          publish_transactions(account, account_payload)
          publish_balance(account, account_payload)
          upsert_profile(account, account_payload)
        end
      end
    end

    private

      def account_for(account_payload)
        review = account_payload.fetch("review")
        return statement_import.family.accounts.find(review["account_id"]) if review["action"] == "match"

        account_type = review["account_type"].presence || account_payload["account_type"]
        account_class = Accountable.from_type(account_type) || Depository
        subtype = review["account_subtype"].presence || account_payload["subtype"]
        balance = BigDecimal(account_payload["closing_balance"].presence || "0")

        Account.create_and_sync(
          {
            family: statement_import.family,
            name: review["account_name"].presence || account_payload["name"],
            balance: balance,
            cash_balance: balance,
            currency: review["currency"].presence || account_payload["currency"].presence || statement_import.family.currency,
            accountable_type: account_class.name,
            accountable_attributes: subtype.present? ? { subtype: subtype } : {},
            import: statement_import
          },
          skip_initial_sync: true
        )
      end

      def publish_transactions(account, account_payload)
        Array(account_payload["transactions"]).each do |txn|
          external_id = txn["external_id"].presence || fallback_external_id(account_payload, txn)
          next if account.entries.exists?(source: "statement_import", external_id: external_id)

          transaction = Transaction.new
          entry = Entry.new(
            account: account,
            date: Date.parse(txn["date"].to_s),
            amount: BigDecimal(txn["amount"].to_s),
            currency: txn["currency"].presence || account.currency,
            name: txn["name"].presence || "Imported transaction",
            notes: txn["notes"],
            import: statement_import,
            import_locked: true,
            source: "statement_import",
            external_id: external_id,
            entryable: transaction
          )
          entry.save!
        end
      end

      def publish_balance(account, account_payload)
        return if account_payload["closing_balance"].blank?

        balance_date = balance_date_for(account_payload) || Date.current
        existing = account.entries.valuations.find_by(date: balance_date)
        result = if existing
          account.update_reconciliation(existing, balance: BigDecimal(account_payload["closing_balance"].to_s), date: balance_date)
        else
          account.create_reconciliation(balance: BigDecimal(account_payload["closing_balance"].to_s), date: balance_date)
        end
        raise result.error_message unless result.success?

        account.update!(balance: BigDecimal(account_payload["closing_balance"].to_s))
      end

      def upsert_profile(account, account_payload)
        profile = statement_import.family.statement_profiles.find_or_initialize_by(
          provider: statement_import.provider,
          source_id: account_payload["source_id"]
        )
        profile.update!(
          account: account,
          source_name: account_payload["name"],
          account_type: account.accountable_type,
          account_subtype: account.subtype,
          currency: account.currency,
          last_statement_end_on: balance_date_for(account_payload),
          metadata: {
            "file_type" => statement_import.file_type,
            "last_import_id" => statement_import.id
          }
        )
      end

      def fallback_external_id(account_payload, txn)
        [ account_payload["source_id"], txn["date"], txn["amount"], txn["name"] ].join(":")
      end

      def balance_date_for(account_payload)
        Date.parse(account_payload["balance_date"].presence || statement_import.statement_period["end_date"].to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
