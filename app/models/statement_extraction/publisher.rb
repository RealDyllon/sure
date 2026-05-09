module StatementExtraction
  class Publisher
    attr_reader :statement_import

    def initialize(statement_import)
      @statement_import = statement_import
    end

    def publish!
      raise Import::MappingError, "Statement import requires account review before publishing" unless statement_import.review_complete?

      @published_transaction_ids = []

      Import.transaction do
        statement_import.extracted_accounts.each do |account_payload|
          account = account_for(account_payload)
          publish_transactions(account, account_payload)
          publish_trades(account, account_payload)
          publish_balance(account, account_payload)
          upsert_profile(account, account_payload)
        end
      end

      enqueue_enrichment_job
    end

    private

      def account_for(account_payload)
        review = account_payload.fetch("review")
        return statement_import.family.accounts.find(review["account_id"]) if review["action"] == "match"
        profile_account = reuse_profile_account(account_payload)
        return profile_account if profile_account

        account_type = review["account_type"].presence || account_payload["account_type"]
        account_class = Accountable.from_type(account_type) || Depository
        subtype = review["account_subtype"].presence || account_payload["subtype"]
        balance = BigDecimal(account_payload["closing_balance"].presence || "0")
        cash_balance = BigDecimal(account_payload["cash_balance"].presence || account_payload["closing_balance"].presence || "0")

        Account.create_and_sync(
          {
            family: statement_import.family,
            name: review["account_name"].presence || account_payload["name"],
            balance: balance,
            cash_balance: cash_balance,
            currency: review["currency"].presence || account_payload["currency"].presence || statement_import.family.currency,
            accountable_type: account_class.name,
            accountable_attributes: subtype.present? ? { subtype: subtype } : {},
            import: statement_import
          },
          skip_initial_sync: true
        )
      end

      def reuse_profile_account(account_payload)
        profile = statement_import.family.statement_profiles.find_by(
          provider: statement_import.provider,
          source_id: account_payload["source_id"]
        )
        return unless profile&.account

        profile.account if profile.metadata["last_import_id"].to_s == statement_import.id.to_s
      end

      def publish_transactions(account, account_payload)
        Array(account_payload["transactions"]).each do |txn|
          external_id = txn["external_id"].presence || fallback_external_id(account_payload, txn)
          next if account.entries.exists?(source: "statement_import", external_id: external_id)

          transaction = Transaction.new
          entry = Entry.new(
            account: account,
            date: Date.parse(txn["date"].to_s),
            amount: transaction_amount_for(txn),
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
          @published_transaction_ids << transaction.id
        end
      end

      def enqueue_enrichment_job
        return if @published_transaction_ids.blank?

        StatementImportEnrichmentJob.perform_later(statement_import, transaction_ids: @published_transaction_ids)
      end

      def publish_trades(account, account_payload)
        Array(account_payload["trades"]).each do |trade_payload|
          external_id = trade_payload["external_id"].presence || fallback_trade_external_id(account_payload, trade_payload)
          next if account.entries.exists?(source: "statement_import", external_id: external_id)

          security = security_for(trade_payload)
          next unless security

          trade = Trade.new(
            security: security,
            qty: BigDecimal(trade_payload["qty"].to_s),
            price: BigDecimal(trade_payload["price"].to_s),
            currency: trade_payload["currency"].presence || account.currency,
            investment_activity_label: trade_payload["activity_label"].presence || activity_label_for(trade_payload["qty"])
          )
          entry = Entry.new(
            account: account,
            date: Date.parse(trade_payload["date"].to_s),
            amount: BigDecimal(trade_payload["amount"].presence || "0"),
            currency: trade_payload["currency"].presence || account.currency,
            name: trade_payload["name"].presence || trade_name_for(trade_payload),
            import: statement_import,
            import_locked: true,
            source: "statement_import",
            external_id: external_id,
            entryable: trade
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
        account.update!(cash_balance: BigDecimal(account_payload["cash_balance"].to_s)) if account_payload["cash_balance"].present?
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
            "last_import_id" => statement_import.id,
            "counts" => {
              "transactions" => Array(account_payload["transactions"]).size,
              "trades" => Array(account_payload["trades"]).size,
              "positions" => Array(account_payload["positions"]).size
            }
          }
        )
      end

      def fallback_external_id(account_payload, txn)
        [ account_payload["source_id"], txn["date"], txn["amount"], txn["name"] ].join(":")
      end

      def transaction_amount_for(txn)
        amount = BigDecimal(txn["amount"].to_s)
        statement_import.file_type == "pdf" ? -amount : amount
      end

      def fallback_trade_external_id(account_payload, trade_payload)
        [
          account_payload["source_id"],
          "trade",
          trade_payload["date"],
          trade_payload["ticker"],
          trade_payload["qty"],
          trade_payload["price"],
          trade_payload["amount"]
        ].join(":")
      end

      def security_for(trade_payload)
        ticker = trade_payload["ticker"].to_s.upcase
        return nil if ticker.blank?

        @security_cache ||= {}
        cache_key = [ ticker, trade_payload["exchange_operating_mic"] ].compact.join(":")
        @security_cache[cache_key] ||= Security::Resolver.new(
          ticker,
          exchange_operating_mic: trade_payload["exchange_operating_mic"].presence
        ).resolve
      end

      def activity_label_for(qty)
        BigDecimal(qty.to_s).negative? ? "Sell" : "Buy"
      end

      def trade_name_for(trade_payload)
        Trade.build_name(activity_label_for(trade_payload["qty"]).downcase, trade_payload["qty"], trade_payload["ticker"])
      end

      def balance_date_for(account_payload)
        Date.parse(account_payload["balance_date"].presence || statement_import.statement_period["end_date"].to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
