module StatementExtraction
  class Publisher
    def initialize(statement_import)
      @import = statement_import
      @journal = { "published" => true, "reconciled" => [], "valuations" => [], "profiles" => [] }
    end

    def publish!
      raise Import::MappingError unless @import.review_complete?
      @import.extracted_accounts.each do |payload|
        account = account_for(payload)
        account.lock!
        @import.statement_import_accounts.create!(account: account, source_id: payload.fetch("source_id"))
        publish_transactions(account, payload)
        publish_trades(account, payload)
        publish_balance(account, payload)
        remember_profile(account, payload)
      end
      @import.update!(publication_journal: @journal)
    end

    def revert!
      raise Import::MappingError unless @import.manageable_by?(@import.initiating_user)
      @journal = @import.publication_journal
      @import.statement_import_accounts.each do |link|
        raise Import::MappingError unless @import.authorized_accounts.exists?(id: link.account_id)
        link.account.lock!
      end
      # Never delete an account that acquired unrelated entries or a provider link.
      @import.accounts.each do |account|
        raise Import::MappingError if account.entries.where("import_id IS NULL OR import_id != ?", @import.id).exists? || account.linked?
      end
      @journal.fetch("valuations", []).each do |record|
        entry = Entry.find(record.fetch("id"))
        raise Import::MappingError unless entry.amount.to_s == record.fetch("published_amount") && entry.updated_at.iso8601(6) == record.fetch("published_at")
        entry.update!(record.fetch("before"))
      end
      @journal.fetch("reconciled", []).each do |record|
        entry = Entry.find_by(id: record.fetch("id"))
        next unless entry && entry.reconciled_by_statement_id == @import.account_statement_id
        entry.update!(record.fetch("before"))
      end
      @journal.fetch("profiles", []).each do |record|
        profile = StatementProfile.find_by(id: record.fetch("id"))
        next unless profile && profile.metadata["last_import_id"] == @import.id
        record["before"] ? profile.update!(record["before"]) : profile.destroy!
      end
      @import.entries.destroy_all
      @import.statement_import_accounts.destroy_all
      @import.accounts.destroy_all
    end

    private
      def account_for(payload)
        review = payload.fetch("review")
        return @import.authorized_accounts.find(review.fetch("account_id")) if review.fetch("action") == "match"
        dates = (Array(payload["transactions"]) + Array(payload["trades"])).map { |row| Date.iso8601(row.fetch("date")) }
        opening_date = (dates.min || Date.current) - 1
        account = Account.create_and_sync({ family: @import.family, name: review.fetch("account_name"), currency: review.fetch("currency"), balance: 0, accountable_type: review.fetch("account_type"), accountable_attributes: review["account_subtype"].present? ? { subtype: review["account_subtype"] } : {}, import: @import, owner: @import.initiating_user }, skip_initial_sync: true, opening_balance_date: opening_date)
        account.entries.update_all(import_id: @import.id)
        account
      end

      def publish_transactions(account, payload)
        adapter = Account::ProviderImportAdapter.new(account)
        claimed = []
        Array(payload["transactions"]).each_with_index do |row, index|
          amount = BigDecimal(row.fetch("amount").to_s)
          amount = -amount if @import.file_type == "pdf"
          currency = row["currency"].presence || account.currency
          date = Date.iso8601(row.fetch("date"))
          existing = adapter.find_duplicate_transaction(date: date, amount: amount, currency: currency, exclude_entry_ids: claimed, date_window: 3, include_provider_entries: true)
          if existing
            claimed << existing.id
            reconcile(existing)
          else
            entry = account.entries.create!(date: date, amount: amount, currency: currency, name: row["name"].presence || "Imported transaction", notes: row["notes"], entryable: Transaction.new, import: @import, import_locked: true, source: "statement_import", external_id: occurrence_id(payload, "transaction", index), reconciled_at: Time.current, reconciled_by_statement: @import.account_statement)
            claimed << entry.id
          end
        end
      end

      def publish_trades(account, payload)
        claimed = []
        Array(payload["trades"]).each_with_index do |row, index|
          raise Import::MappingError unless account.accountable_type == "Investment"
          security = Security::Resolver.new(row.fetch("ticker"), exchange_operating_mic: row["exchange_operating_mic"].presence).resolve
          raise Import::MappingError unless security
          qty = BigDecimal(row.fetch("qty").to_s)
          price = BigDecimal(row.fetch("price").to_s)
          amount = BigDecimal(row.fetch("amount").to_s)
          currency = row["currency"].presence || account.currency
          date = Date.iso8601(row.fetch("date"))
          existing = account.entries.trades.joins("INNER JOIN trades ON trades.id = entries.entryable_id").where(date: date, currency: currency, amount: amount).where(trades: { security_id: security.id, qty: qty, price: price }).where.not(id: claimed).first
          if existing
            claimed << existing.id
            reconcile(existing)
          else
            trade = Trade.new(security: security, qty: qty, price: price, currency: currency, investment_activity_label: row["activity_label"].presence || (qty.negative? ? "Sell" : "Buy"))
            entry = account.entries.create!(date: date, amount: amount, currency: currency, name: row["name"].presence || "Imported trade", entryable: trade, import: @import, import_locked: true, source: "statement_import", external_id: occurrence_id(payload, "trade", index), reconciled_at: Time.current, reconciled_by_statement: @import.account_statement)
            claimed << entry.id
          end
        end
      end

      def reconcile(entry)
        @journal["reconciled"] << { "id" => entry.id, "before" => entry.attributes.slice("reconciled_at", "reconciled_by_statement_id") }
        entry.update!(reconciled_at: Time.current, reconciled_by_statement: @import.account_statement)
      end

      def publish_balance(account, payload)
        return if payload["closing_balance"].blank?
        date = Date.iso8601(payload["balance_date"].presence || @import.statement_period.fetch("end_date"))
        amount = BigDecimal(payload["closing_balance"].to_s)
        existing = account.entries.valuations.find_by(date: date)
        if existing
          before = existing.attributes.slice("amount", "currency", "date")
          existing.update!(amount: amount, currency: account.currency)
          @journal["valuations"] << { "id" => existing.id, "before" => before, "published_amount" => existing.amount.to_s, "published_at" => existing.updated_at.iso8601(6) }
        else
          account.entries.create!(date: date, amount: amount, currency: account.currency, name: Valuation.build_reconciliation_name(account.accountable_type), entryable: Valuation.new(kind: "reconciliation"), import: @import, source: "statement_import", external_id: occurrence_id(payload, "valuation", 0))
        end
      end

      def remember_profile(account, payload)
        profile = @import.family.statement_profiles.find_or_initialize_by(provider: @import.provider, source_id: payload.fetch("source_id"))
        before = profile.persisted? ? profile.attributes.except("id", "created_at", "updated_at") : nil
        profile.update!(account: account, source_name: payload["name"], account_type: account.accountable_type, account_subtype: account.subtype, currency: account.currency, metadata: { "last_import_id" => @import.id })
        @journal["profiles"] << { "id" => profile.id, "before" => before }
      end

      def occurrence_id(payload, type, index)
        Digest::SHA256.hexdigest([ @import.account_statement.content_sha256, payload.fetch("source_id"), type, index ].join("/"))
      end
  end
end
