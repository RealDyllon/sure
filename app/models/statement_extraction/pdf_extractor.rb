module StatementExtraction
  class PdfExtractor
    attr_reader :statement_import

    def initialize(statement_import)
      @statement_import = statement_import
    end

    def extract
      provider = Provider::Registry.default_llm_provider
      raise "AI provider not configured" unless provider

      response = provider.extract_bank_statement(
        pdf_content: statement_import.pdf_file_content,
        family: statement_import.family,
        pdf_password: statement_import.statement_pdf_password
      )
      raise(response.error&.message || "Unknown statement extraction error") unless response.success?

      data = response.data.deep_stringify_keys
      provider_name = detect_provider(data)
      account_payloads = extracted_account_payloads(data)
      use_document_activity_fallback = data["accounts"].present? && account_payloads.one?
      accounts = account_payloads.map do |account_data|
        normalize_account(provider_name, account_data, data, use_document_activity_fallback: use_document_activity_fallback)
      end

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
          "opening_balance" => decimal_string(data["opening_balance"]),
          "closing_balance" => decimal_string(data["closing_balance"].presence || data["net_liquidation_value"]),
          "cash_balance" => decimal_string(data["cash_balance"]),
          "balance_date" => data["balance_date"].presence || data.dig("period", "end_date") || document_data.dig("period", "end_date") || document_data.dig("statement_period", "end_date"),
          "transactions" => normalize_transactions(provider_name, account_number, data),
          "trades" => normalize_trades(provider_name, account_number, data),
          "positions" => normalize_positions(data)
        }
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
