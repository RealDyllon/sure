module StatementExtraction
  class PdfExtractor
    attr_reader :statement_import

    def initialize(statement_import)
      @statement_import = statement_import
    end

    def extract(progress_callback: nil)
      provider = Provider::Registry.default_llm_provider
      raise "AI provider not configured" unless provider

      response = provider.extract_bank_statement(
        pdf_content: statement_import.pdf_file_content,
        family: statement_import.family,
        pdf_password: statement_import.statement_pdf_password,
        progress_callback: progress_callback
      )
      raise(response.error&.message || "Unknown statement extraction error") unless response.success?

      data = response.data.deep_stringify_keys
      provider_name = detect_provider(data)
      account_payloads = extracted_account_payloads(data)
      use_document_activity_fallback = data["accounts"].present? && account_payloads.one?
      accounts = account_payloads.map do |account_data|
        normalize_account(provider_name, account_data, data, use_document_activity_fallback: use_document_activity_fallback)
      end
      accounts = merge_duplicate_accounts(accounts)
      if unassigned_document_activity?(data, account_payloads)
        unassigned_account = normalize_account(provider_name, unassigned_account_payload(provider_name, data), data)
        unassigned_account = remove_assigned_activity(unassigned_account, accounts)
        accounts << unassigned_account if normalized_activity_present?(unassigned_account)
      end
      accounts = ensure_unique_source_ids(accounts)

      Result.new(
        provider: provider_name,
        file_type: "pdf",
        statement_period: data["period"] || data["statement_period"] || {},
        accounts: accounts
      )
    end

    private
      def extracted_account_payloads(data)
        accounts = Array(data["accounts"]).reject(&:blank?)
        accounts.presence || [ data ]
      end

      def unassigned_document_activity?(data, account_payloads)
        data["accounts"].present? && account_payloads.many? && document_activity_present?(data)
      end

      def document_activity_present?(data)
        %w[transactions cash_transactions trades positions].any? { |key| Array(data[key]).present? }
      end

      def unassigned_account_payload(provider_name, data)
        {
          "account_name" => "Unassigned #{provider_name.upcase} Activity",
          "account_number" => "unassigned",
          "account_type" => account_type_for(provider_name, data),
          "subtype" => subtype_for(provider_name, data),
          "currency" => data["currency"].presence || data["base_currency"].presence || statement_import.family.currency,
          "transactions" => Array(data["transactions"]),
          "cash_transactions" => Array(data["cash_transactions"]),
          "trades" => Array(data["trades"]),
          "positions" => Array(data["positions"])
        }
      end

      def normalize_account(provider_name, account_data, document_data, use_document_activity_fallback: false)
        data = document_data.merge(account_data)
        data = apply_document_activity_fallback(data, account_data, document_data) if use_document_activity_fallback
        account_number = normalized_account_number(data["account_number"]).presence || data["account_id"].presence || "default"

        {
          "source_id" => source_id_for(provider_name, account_number),
          "name" => data["account_name"].presence || data["name"].presence || account_name_for(provider_name, account_number),
          "account_type" => account_type_for(provider_name, data),
          "subtype" => subtype_for(provider_name, data),
          "currency" => data["currency"].presence || data["base_currency"].presence || statement_import.family.currency,
          "opening_balance" => decimal_string(account_scoped_value(account_data, document_data, "opening_balance", use_document_activity_fallback: use_document_activity_fallback)),
          "closing_balance" => decimal_string(account_scoped_value(account_data, document_data, "closing_balance", "net_liquidation_value", use_document_activity_fallback: use_document_activity_fallback)),
          "cash_balance" => decimal_string(account_scoped_value(account_data, document_data, "cash_balance", use_document_activity_fallback: use_document_activity_fallback)),
          "balance_date" => data["balance_date"].presence || data.dig("period", "end_date") || document_data.dig("period", "end_date") || document_data.dig("statement_period", "end_date"),
          "transactions" => normalize_transactions(provider_name, account_number, data),
          "trades" => normalize_trades(provider_name, account_number, data),
          "positions" => normalize_positions(data)
        }
      end

      def account_scoped_value(account_data, document_data, *keys, use_document_activity_fallback:)
        keys.each do |key|
          return account_data[key] if account_data[key].present?
        end

        return nil if document_data["accounts"].present? && !use_document_activity_fallback

        keys.each do |key|
          return document_data[key] if document_data[key].present?
        end

        nil
      end

      def merge_duplicate_accounts(accounts)
        accounts.each_with_object([]) do |account, merged|
          existing = merged.find { |candidate| mergeable_account?(candidate, account) }

          if existing
            existing.replace(merged_account(existing, account))
          else
            merged << account
          end
        end
      end

      def mergeable_account?(left, right)
        left["source_id"] == right["source_id"] &&
          normalized_name(left["name"]) == normalized_name(right["name"]) &&
          left["currency"].to_s == right["currency"].to_s
      end

      def merged_account(left, right)
        preferred_metadata = normalized_activity_present?(right) ? right : left

        left.merge(
          "account_type" => preferred_metadata["account_type"].presence || left["account_type"] || right["account_type"],
          "subtype" => preferred_metadata["subtype"].presence || left["subtype"] || right["subtype"],
          "opening_balance" => left["opening_balance"].presence || right["opening_balance"],
          "closing_balance" => left["closing_balance"].presence || right["closing_balance"],
          "cash_balance" => left["cash_balance"].presence || right["cash_balance"],
          "balance_date" => left["balance_date"].presence || right["balance_date"],
          "transactions" => merged_activity(left["transactions"], right["transactions"], "transactions"),
          "trades" => merged_activity(left["trades"], right["trades"], "trades"),
          "positions" => merged_activity(left["positions"], right["positions"], "positions")
        )
      end

      def merged_activity(left, right, activity_type)
        seen = {}

        Array(left).concat(Array(right)).each_with_object([]) do |item, merged|
          fingerprint = activity_fingerprint(activity_type, item)
          next if seen[fingerprint]

          seen[fingerprint] = true
          merged << item
        end
      end

      def remove_assigned_activity(account, assigned_accounts)
        %w[transactions trades positions].each_with_object(account.dup) do |activity_type, filtered_account|
          assigned_fingerprints = assigned_accounts.flat_map { |assigned| Array(assigned[activity_type]) }
            .each_with_object({}) do |activity, fingerprints|
              fingerprints[activity_fingerprint(activity_type, activity)] = true
            end

          filtered_account[activity_type] = Array(filtered_account[activity_type]).reject do |activity|
            assigned_fingerprints[activity_fingerprint(activity_type, activity)]
          end
        end
      end

      def normalized_activity_present?(account)
        %w[transactions trades positions].any? { |key| Array(account[key]).present? }
      end

      def activity_fingerprint(activity_type, activity)
        case activity_type
        when "transactions"
          [
            activity["date"],
            activity["amount"].to_s,
            normalized_name(activity["name"]),
            activity["currency"]
          ]
        when "trades"
          [
            activity["date"],
            activity["ticker"].to_s.upcase,
            activity["qty"].to_s,
            activity["price"].to_s,
            activity["amount"].to_s,
            activity["currency"]
          ]
        when "positions"
          [
            activity["date"],
            activity["ticker"].to_s.upcase,
            activity["qty"].to_s,
            activity["market_value"].to_s,
            activity["currency"]
          ]
        end
      end

      def normalized_name(value)
        value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
      end

      def ensure_unique_source_ids(accounts)
        seen = {}

        accounts.map.with_index do |account, index|
          source_id = account["source_id"]
          if seen[source_id]
            account = account.merge("source_id" => unique_source_id(source_id, account, index, seen))
          end

          seen[account["source_id"]] = true
          account
        end
      end

      def unique_source_id(source_id, account, index, seen)
        suffix = source_id_suffix(account).presence || "account-#{index + 1}"
        candidate = "#{source_id}-#{suffix}"
        counter = 2

        while seen[candidate]
          candidate = "#{source_id}-#{suffix}-#{counter}"
          counter += 1
        end

        candidate
      end

      def source_id_suffix(account)
        [
          account["name"],
          account["subtype"]
        ].compact_blank.join("-").parameterize
      end

      def apply_document_activity_fallback(data, account_data, document_data)
        %w[transactions cash_transactions trades positions].each do |key|
          next if Array(account_data[key]).present?
          next if Array(document_data[key]).blank?

          data[key] = document_data[key]
        end

        data
      end

      def normalize_transactions(provider_name, account_number, data)
        statement_period = data["period"].presence || data["statement_period"].presence || {}

        Array(data["transactions"].presence || data["cash_transactions"]).map do |txn|
          date = normalize_date_to_statement_period(txn["date"], statement_period)
          name = txn["name"] || txn["description"] || "Imported transaction"
          amount = txn["amount"].to_s
          {
            "date" => date,
            "name" => name,
            "amount" => amount,
            "currency" => txn["currency"].presence || data["currency"].presence || data["base_currency"].presence || statement_import.family.currency,
            "external_id" => [ provider_name, account_number, date, amount, name ].join(":")
          }
        end
      end

      def normalize_date_to_statement_period(date, statement_period)
        parsed_date = parse_date(date)
        return date.to_s unless parsed_date

        period_start = parse_date(statement_period["start_date"])
        period_end = parse_date(statement_period["end_date"])
        return parsed_date.iso8601 unless period_start && period_end
        return parsed_date.iso8601 if parsed_date.between?(period_start, period_end)

        candidate_date_for_period(parsed_date, period_start, period_end)&.iso8601 || parsed_date.iso8601
      end

      def candidate_date_for_period(parsed_date, period_start, period_end)
        [ period_start.year, period_end.year ].uniq.filter_map do |year|
          Date.new(year, parsed_date.month, parsed_date.day)
        rescue Date::Error
          nil
        end.find { |candidate| candidate.between?(period_start, period_end) }
      end

      def parse_date(value)
        return if value.blank?

        Date.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def detect_provider(data)
        text = [ data["bank_name"], statement_import.original_filename ].join(" ").downcase
        return "ibkr" if text.include?("ibkr") || text.include?("interactive brokers")
        return "paylah" if text.include?("paylah")
        return "uob" if text.include?("uob")
        return "cpf" if text.include?("cpf")
        return "dbs" if text.include?("dbs")

        "dbs"
      end

      def source_id_for(provider_name, account_number)
        suffix = normalized_account_number(account_number)
        "#{provider_name}:#{suffix.presence || "default"}"
      end

      def account_name_for(provider_name, account_number)
        return "IBKR #{account_number.to_s.scan(/\d/).last(4).join.presence || "Statement"}" if provider_name == "ibkr"

        [ provider_name.upcase, account_number ].compact.join(" ").presence || "#{provider_name.upcase} Statement"
      end

      def account_type_for(provider_name, data)
        return "Investment" if provider_name == "ibkr"
        return data["account_type"] if data["account_type"].present?

        data["document_type"] == "credit_card_statement" ? "CreditCard" : "Depository"
      end

      def subtype_for(provider_name, data)
        return "brokerage" if provider_name == "ibkr"
        return data["subtype"] if data["subtype"].present?

        data["document_type"] == "credit_card_statement" ? "credit_card" : "checking"
      end

      def normalize_trades(provider_name, account_number, data)
        return [] unless provider_name == "ibkr"

        Array(data["trades"]).map do |trade|
          date = trade["date"].to_s
          ticker = trade["ticker"].presence || trade["symbol"].to_s
          qty = trade["qty"].presence || trade["quantity"].to_s
          price = trade["price"].to_s
          amount = trade["amount"].presence || trade["proceeds"].to_s
          name = trade["name"].presence || trade["description"].presence || "#{qty.to_d.negative? ? "Sell" : "Buy"} #{ticker}"

          {
            "date" => date,
            "name" => name,
            "ticker" => ticker.to_s.upcase,
            "exchange_operating_mic" => trade["exchange_operating_mic"],
            "qty" => qty.to_s,
            "price" => price,
            "amount" => amount.to_s,
            "currency" => trade["currency"].presence || data["currency"].presence || data["base_currency"].presence || statement_import.family.currency,
            "activity_label" => trade["activity_label"].presence || (qty.to_d.negative? ? "Sell" : "Buy"),
            "external_id" => [ provider_name, account_number, "trade", date, ticker, qty, price, amount ].join(":")
          }
        end
      end

      def normalize_positions(data)
        Array(data["positions"]).map do |position|
          {
            "date" => position["date"].presence || data.dig("period", "end_date"),
            "name" => position["name"].presence || position["description"],
            "ticker" => (position["ticker"].presence || position["symbol"]).to_s.upcase,
            "qty" => (position["qty"].presence || position["quantity"]).to_s,
            "price" => position["price"].to_s,
            "market_value" => (position["market_value"].presence || position["amount"]).to_s,
            "currency" => position["currency"].presence || data["currency"].presence || data["base_currency"].presence || statement_import.family.currency
          }
        end
      end

      def decimal_string(value)
        return nil if value.blank?
        return format("%.2f", value) if value.is_a?(Numeric)

        value.to_s
      end

      def normalized_account_number(account_number)
        return if account_number.blank?

        digits = account_number.to_s.scan(/\d/)
        digits.size >= 4 ? digits.last(4).join : account_number.to_s
      end
  end
end
