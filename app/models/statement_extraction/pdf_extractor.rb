module StatementExtraction
  class PdfExtractor
    attr_reader :statement_import

    def initialize(statement_import)
      @statement_import = statement_import
    end

    def extract
      provider = Provider::Registry.get_provider(:openai)
      raise "AI provider not configured" unless provider

      response = provider.extract_bank_statement(
        pdf_content: statement_import.pdf_file_content,
        family: statement_import.family,
        pdf_password: statement_import.statement_pdf_password
      )
      raise(response.error&.message || "Unknown statement extraction error") unless response.success?

      data = response.data.deep_stringify_keys
      provider_name = detect_provider(data)
      account_number = data["account_number"].presence || data["account_id"].presence || "default"
      account = {
        "source_id" => source_id_for(provider_name, account_number),
        "name" => account_name_for(provider_name, account_number),
        "account_type" => account_type_for(provider_name, data),
        "subtype" => subtype_for(provider_name, data),
        "currency" => data["currency"].presence || data["base_currency"].presence || statement_import.family.currency,
        "opening_balance" => data["opening_balance"].to_s,
        "closing_balance" => (data["closing_balance"].presence || data["net_liquidation_value"]).to_s,
        "cash_balance" => data["cash_balance"].to_s,
        "balance_date" => data.dig("period", "end_date"),
        "transactions" => Array(data["transactions"].presence || data["cash_transactions"]).map do |txn|
          date = txn["date"].to_s
          name = txn["name"] || txn["description"] || "Imported transaction"
          amount = txn["amount"].to_s
          {
            "date" => date,
            "name" => name,
            "amount" => amount,
            "currency" => txn["currency"].presence || data["currency"].presence || data["base_currency"].presence || statement_import.family.currency,
            "external_id" => [ provider_name, account_number, date, amount, name ].join(":")
          }
        end,
        "trades" => normalize_trades(provider_name, account_number, data),
        "positions" => normalize_positions(data)
      }

      Result.new(
        provider: provider_name,
        file_type: "pdf",
        statement_period: data["period"] || {},
        accounts: [ account ]
      )
    end

    private

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
        suffix = provider_name == "ibkr" ? account_number.to_s.scan(/\d/).last(4).join.presence : account_number
        "#{provider_name}:#{suffix.presence || "default"}"
      end

      def account_name_for(provider_name, account_number)
        return "IBKR #{account_number.to_s.scan(/\d/).last(4).join.presence || "Statement"}" if provider_name == "ibkr"

        [ provider_name.upcase, account_number ].compact.join(" ").presence || "#{provider_name.upcase} Statement"
      end

      def account_type_for(provider_name, data)
        return "Investment" if provider_name == "ibkr"

        data["document_type"] == "credit_card_statement" ? "CreditCard" : "Depository"
      end

      def subtype_for(provider_name, data)
        return "brokerage" if provider_name == "ibkr"

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
  end
end
