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
        return "dbs" if downcased_filename.include?("dbs")

        "dbs"
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
        dates = accounts.flat_map { |account| account["transactions"].map { |txn| txn["date"] } + [ account["balance_date"] ] }.compact
        parsed = dates.filter_map { |date| parse_date(date) }
        return {} if parsed.empty?

        { "start_date" => parsed.min.iso8601, "end_date" => parsed.max.iso8601 }
      end
  end
end
