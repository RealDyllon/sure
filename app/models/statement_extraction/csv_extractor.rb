module StatementExtraction
  class CsvExtractor
    CPF_BUCKETS = {
      "ordinary account" => [ "ordinary", "CPF Ordinary Account", "cpf_ordinary" ],
      "special account" => [ "special", "CPF Special Account", "cpf_special" ],
      "medisave account" => [ "medisave", "CPF MediSave Account", "cpf_medisave" ],
      "retirement account" => [ "retirement", "CPF Retirement Account", "cpf_retirement" ]
    }.freeze

    attr_reader :raw_csv, :filename

    def initialize(raw_csv:, filename: nil)
      @raw_csv = raw_csv.to_s
      @filename = filename.to_s
    end

    def extract
      provider = detect_provider
      rows = parsed_rows

      return extract_cpf(rows) if provider == "cpf"
      return extract_ibkr(rows) if provider == "ibkr"

      extract_bank_or_wallet(rows, provider: provider)
    end

    private

      def parsed_rows
        CSV.parse(raw_csv.strip, headers: true, converters: [ ->(value) { value&.strip } ], liberal_parsing: true)
      end

      def headers
        @headers ||= parsed_rows.headers.compact.map { |header| normalize_key(header) }
      end

      def detect_provider
        downcased_filename = filename.downcase
        return "paylah" if downcased_filename.include?("paylah") || headers.any? { |header| header.include?("paylah") }
        return "uob" if downcased_filename.include?("uob") || headers.any? { |header| header.include?("uob") }
        return "cpf" if downcased_filename.include?("cpf") || headers.include?("account") && headers.any? { |header| header.include?("contribution") }
        return "ibkr" if ibkr_statement?(downcased_filename)
        return "dbs" if downcased_filename.include?("dbs")

        "dbs"
      end

      def ibkr_statement?(downcased_filename)
          downcased_filename.include?("ibkr") ||
          downcased_filename.include?("interactivebrokers") ||
          downcased_filename.include?("interactive brokers") ||
          downcased_filename.include?("interactive_brokers") ||
          downcased_filename.include?("interactive-brokers") ||
          (headers.include?("section") && headers.any? { |header| header.include?("account id") || header.include?("base currency") }) ||
          raw_csv.downcase.include?("interactive brokers")
      end

      def extract_bank_or_wallet(rows, provider:)
        grouped = rows.group_by { |row| source_id_for(row, provider: provider) }
        accounts = grouped.map do |source_id, account_rows|
          last_row = account_rows.last
          source_suffix = source_id.split(":").last
          transactions = account_rows.map do |row|
            amount = amount_for(row)
            date = date_for(row)
            name = value_at(row, "description", "name", "transaction description", "details").presence || "Imported transaction"

            {
              "date" => date,
              "name" => name,
              "amount" => amount,
              "currency" => currency_for(row),
              "external_id" => [ source_id, date, amount, name ].join(":")
            }
          end

          {
            "source_id" => source_id,
            "name" => "#{provider.upcase} #{source_suffix}",
            "account_type" => provider == "uob" && credit_card_statement?(account_rows) ? "CreditCard" : "Depository",
            "subtype" => provider == "uob" && credit_card_statement?(account_rows) ? "credit_card" : "checking",
            "currency" => currency_for(last_row),
            "opening_balance" => value_at(account_rows.first, "balance"),
            "closing_balance" => value_at(last_row, "balance"),
            "balance_date" => date_for(last_row),
            "transactions" => transactions
          }
        end

        Result.new(
          provider: provider,
          file_type: "csv",
          statement_period: period_from(accounts),
          accounts: accounts
        )
      end

      def extract_cpf(rows)
        accounts = rows.map do |row|
          bucket_name = value_at(row, "account").to_s.downcase
          bucket_key, name, subtype = CPF_BUCKETS.fetch(bucket_name) do
            normalized = bucket_name.presence || "other"
            [ normalized.parameterize, "CPF #{normalized.titleize}", "cpf_other" ]
          end

          date = cpf_date_for(row)
          contribution = decimal_string(value_at(row, "contribution"))
          withdrawal = decimal_string(value_at(row, "withdrawal"))
          transactions = []
          transactions << cpf_transaction("Contribution", contribution, date, bucket_key, row) unless contribution.to_d.zero?
          transactions << cpf_transaction("Withdrawal", withdrawal, date, bucket_key, row) unless withdrawal.to_d.zero?

          {
            "source_id" => "cpf:#{bucket_key}",
            "name" => name,
            "account_type" => "Investment",
            "subtype" => subtype,
            "currency" => currency_for(row),
            "closing_balance" => decimal_string(value_at(row, "closing balance", "balance")),
            "balance_date" => date,
            "transactions" => transactions
          }
        end

        Result.new(
          provider: "cpf",
          file_type: "csv",
          statement_period: period_from(accounts),
          accounts: accounts
        )
      end

      def extract_ibkr(rows)
        grouped = rows.group_by { |row| ibkr_source_id_for(row) }
        accounts = grouped.map do |source_id, account_rows|
          suffix = source_id.split(":").last
          currency = ibkr_currency_for(account_rows)
          trades = ibkr_trades_for(account_rows, source_id, currency)
          transactions = ibkr_cash_transactions_for(account_rows, source_id, currency)
          positions = ibkr_positions_for(account_rows, currency)
          balance_row = ibkr_balance_row(account_rows) || account_rows.reverse.find { |row| date_for(row).present? } || account_rows.last

          {
            "source_id" => source_id,
            "name" => "IBKR #{suffix}",
            "account_type" => "Investment",
            "subtype" => "brokerage",
            "currency" => currency,
            "closing_balance" => ibkr_closing_balance_for(balance_row),
            "cash_balance" => decimal_string(value_at(balance_row, "closing balance")),
            "balance_date" => date_for(balance_row),
            "transactions" => transactions,
            "trades" => trades,
            "positions" => positions
          }
        end

        Result.new(
          provider: "ibkr",
          file_type: "csv",
          statement_period: period_from(accounts),
          accounts: accounts
        )
      end

      def ibkr_trades_for(rows, source_id, currency)
        ibkr_rows_for(rows, "trades").map do |row|
          date = date_for(row)
          ticker = value_at(row, "symbol", "ticker").to_s.upcase
          qty = ibkr_trade_quantity(row)
          price = decimal_string(value_at(row, "price", "t price", "trade price"))
          amount = decimal_string(value_at(row, "amount", "proceeds"))
          name = value_at(row, "description").presence || "#{ibkr_activity_label(qty)} #{ticker}"

          {
            "date" => date,
            "name" => name,
            "ticker" => ticker,
            "exchange_operating_mic" => value_at(row, "exchange operating mic", "exchange"),
            "qty" => qty,
            "price" => price,
            "amount" => amount,
            "currency" => value_at(row, "currency").presence || currency,
            "activity_label" => ibkr_activity_label(qty),
            "external_id" => [ source_id, "trade", date, ticker, qty, price, amount ].join(":")
          }
        end
      end

      def ibkr_cash_transactions_for(rows, source_id, currency)
        ibkr_rows_for(rows, "cash transactions").filter_map do |row|
          amount = decimal_string(value_at(row, "amount"))
          next if amount.to_d.zero?

          date = date_for(row)
          name = value_at(row, "description", "subsection").presence || "IBKR cash activity"

          {
            "date" => date,
            "name" => name,
            "amount" => amount,
            "currency" => value_at(row, "currency").presence || currency,
            "external_id" => [ source_id, "cash", date, amount, name ].join(":")
          }
        end
      end

      def ibkr_positions_for(rows, currency)
        ibkr_rows_for(rows, "positions").map do |row|
          ticker = value_at(row, "symbol", "ticker").to_s.upcase

          {
            "date" => date_for(row),
            "name" => value_at(row, "description").presence || ticker,
            "ticker" => ticker,
            "qty" => decimal_string(value_at(row, "quantity", "qty")),
            "price" => decimal_string(value_at(row, "price", "close price")),
            "market_value" => decimal_string(value_at(row, "amount", "market value")),
            "currency" => value_at(row, "currency").presence || currency
          }
        end
      end

      def ibkr_rows_for(rows, section)
        rows.select { |row| normalize_key(value_at(row, "section")) == section }
      end

      def ibkr_source_id_for(row)
        account_id = value_at(row, "account id", "account number", "account").to_s
        suffix = account_id.scan(/\d/).last(4).join.presence || "default"
        "ibkr:#{suffix}"
      end

      def ibkr_currency_for(rows)
        rows.filter_map { |row| value_at(row, "base currency", "currency") }.first.presence || "USD"
      end

      def ibkr_balance_row(rows)
        rows.reverse.find do |row|
          normalize_key(value_at(row, "section")).in?([ "net asset value", "balances" ]) &&
            (value_at(row, "net liquidation value", "closing balance", "amount").present?)
        end
      end

      def ibkr_closing_balance_for(row)
        decimal_string(value_at(row, "net liquidation value", "closing balance", "amount"))
      end

      def ibkr_trade_quantity(row)
        qty = decimal_string(value_at(row, "quantity", "qty"))
        description = value_at(row, "description").to_s.downcase
        return "-#{qty}" if description.include?("sell") && qty.to_d.positive?

        qty
      end

      def ibkr_activity_label(qty)
        qty.to_d.negative? ? "Sell" : "Buy"
      end

      def cpf_transaction(name, amount, date, bucket_key, row)
        signed_amount = name == "Contribution" ? "-#{amount}" : amount
        {
          "date" => date,
          "name" => "CPF #{name}",
          "amount" => signed_amount,
          "currency" => currency_for(row),
          "external_id" => [ "cpf:#{bucket_key}", date, name, amount ].join(":")
        }
      end

      def source_id_for(row, provider:)
        number = value_at(row, "account number", "account", "card number", "wallet").to_s
        suffix = number.scan(/\d/).last(4).join.presence || "default"
        "#{provider}:#{suffix}"
      end

      def value_at(row, *keys)
        keys.each do |key|
          header = row.headers.find { |candidate| normalize_key(candidate) == normalize_key(key) }
          value = row[header] if header
          return value if value.present?
        end
        nil
      end

      def amount_for(row)
        debit = decimal_string(value_at(row, "debit", "withdrawal", "paid out", "outflow"))
        credit = decimal_string(value_at(row, "credit", "deposit", "paid in", "inflow"))
        amount = decimal_string(value_at(row, "amount"))

        return debit unless debit.to_d.zero?
        return "-#{credit}" unless credit.to_d.zero?

        amount
      end

      def date_for(row)
        raw = value_at(row, "transaction date", "date", "posting date", "posted date")
        parse_date(raw)&.iso8601 || raw.to_s
      end

      def cpf_date_for(row)
        raw = value_at(row, "month", "date")
        parsed = parse_date(raw)
        return parsed.end_of_month.iso8601 if parsed

        raw.to_s
      end

      def parse_date(value)
        return nil if value.blank?

        Date.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def currency_for(row)
        value_at(row, "currency").presence || "SGD"
      end

      def decimal_string(value)
        format("%.2f", BigDecimal(value.to_s.gsub(/[^\d.\-]/, "").presence || "0"))
      end

      def normalize_key(value)
        value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
      end

      def credit_card_statement?(rows)
        rows.any? { |row| row.headers.any? { |header| normalize_key(header).include?("card") } }
      end

      def period_from(accounts)
        dates = accounts.flat_map do |account|
          Array(account["transactions"]).map { |txn| txn["date"] } +
            Array(account["trades"]).map { |trade| trade["date"] } +
            Array(account["positions"]).map { |position| position["date"] } +
            [ account["balance_date"] ]
        end.compact
        parsed = dates.filter_map { |date| parse_date(date) }
        return {} if parsed.empty?

        { "start_date" => parsed.min.iso8601, "end_date" => parsed.max.iso8601 }
      end
  end
end
