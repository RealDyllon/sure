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
      account = {
        "source_id" => "#{provider_name}:#{data["account_number"].presence || "default"}",
        "name" => [ provider_name.upcase, data["account_number"] ].compact.join(" ").presence || "#{provider_name.upcase} Statement",
        "account_type" => data["document_type"] == "credit_card_statement" ? "CreditCard" : "Depository",
        "subtype" => data["document_type"] == "credit_card_statement" ? "credit_card" : "checking",
        "currency" => statement_import.family.currency,
        "opening_balance" => data["opening_balance"].to_s,
        "closing_balance" => data["closing_balance"].to_s,
        "balance_date" => data.dig("period", "end_date"),
        "transactions" => Array(data["transactions"]).map do |txn|
          date = txn["date"].to_s
          name = txn["name"] || txn["description"] || "Imported transaction"
          amount = txn["amount"].to_s
          {
            "date" => date,
            "name" => name,
            "amount" => amount,
            "currency" => statement_import.family.currency,
            "external_id" => [ provider_name, data["account_number"], date, amount, name ].join(":")
          }
        end
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
        return "paylah" if text.include?("paylah")
        return "uob" if text.include?("uob")
        return "cpf" if text.include?("cpf")
        return "dbs" if text.include?("dbs")

        "dbs"
      end
  end
end
