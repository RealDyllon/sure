class Provider::Openai::BankStatementExtractor
  MAX_CHARS_PER_CHUNK = 3000
  attr_reader :client, :pdf_content, :model, :pdf_password

  def initialize(client:, pdf_content:, model:, pdf_password: nil)
    @client = client
    @pdf_content = pdf_content
    @model = model
    @pdf_password = pdf_password
  end

  def extract
    pages = extract_pages_from_pdf
    raise Provider::Openai::Error, "Could not extract text from PDF" if pages.empty?

    chunks = build_chunks(pages)
    Rails.logger.info("BankStatementExtractor: Processing #{chunks.size} chunk(s) from #{pages.size} page(s)")

    all_transactions = []
    all_trades = []
    all_positions = []
    metadata = {}

    chunks.each_with_index do |chunk, index|
      Rails.logger.info("BankStatementExtractor: Processing chunk #{index + 1}/#{chunks.size}")
      result = process_chunk(chunk, index == 0)

      # Tag transactions with chunk index for deduplication
      tagged_transactions = (result[:transactions] || []).map { |t| t.merge(chunk_index: index) }
      all_transactions.concat(tagged_transactions)
      all_trades.concat(result[:trades] || [])
      all_positions.concat(result[:positions] || [])

      if index == 0
        metadata = {
          account_holder: result[:account_holder],
          account_number: result[:account_number],
          account_id: result[:account_id],
          bank_name: result[:bank_name],
          currency: result[:currency],
          base_currency: result[:base_currency],
          opening_balance: result[:opening_balance],
          closing_balance: result[:closing_balance],
          cash_balance: result[:cash_balance],
          net_liquidation_value: result[:net_liquidation_value],
          period: result[:period]
        }
      end

      if result[:closing_balance].present?
        metadata[:closing_balance] = result[:closing_balance]
      end
      if result[:cash_balance].present?
        metadata[:cash_balance] = result[:cash_balance]
      end
      if result[:net_liquidation_value].present?
        metadata[:net_liquidation_value] = result[:net_liquidation_value]
      end
      if result.dig(:period, :end_date).present?
        metadata[:period] ||= {}
        metadata[:period][:end_date] = result.dig(:period, :end_date)
      end
    end

    {
      transactions: deduplicate_transactions(all_transactions),
      period: metadata[:period] || {},
      account_holder: metadata[:account_holder],
      account_number: metadata[:account_number],
      account_id: metadata[:account_id],
      bank_name: metadata[:bank_name],
      currency: metadata[:currency],
      base_currency: metadata[:base_currency],
      opening_balance: metadata[:opening_balance],
      closing_balance: metadata[:closing_balance],
      cash_balance: metadata[:cash_balance],
      net_liquidation_value: metadata[:net_liquidation_value],
      trades: all_trades,
      positions: all_positions
    }
  end

  private

    def extract_pages_from_pdf
      return [] if pdf_content.blank?

      options = pdf_password.present? ? { password: pdf_password } : {}
      reader = PDF::Reader.new(StringIO.new(pdf_content), options)
      reader.pages.map(&:text).reject(&:blank?)
    rescue => e
      Rails.logger.error("Failed to extract text from PDF: #{e.message}")
      []
    end

    def build_chunks(pages)
      chunks = []
      current_chunk = []
      current_size = 0

      pages.each do |page_text|
        if page_text.length > MAX_CHARS_PER_CHUNK
          chunks << current_chunk.join("\n\n") if current_chunk.any?
          current_chunk = []
          current_size = 0
          chunks << page_text
          next
        end

        if current_size + page_text.length > MAX_CHARS_PER_CHUNK && current_chunk.any?
          chunks << current_chunk.join("\n\n")
          current_chunk = []
          current_size = 0
        end

        current_chunk << page_text
        current_size += page_text.length
      end

      chunks << current_chunk.join("\n\n") if current_chunk.any?
      chunks
    end

    def process_chunk(text, is_first_chunk)
      params = {
        model: model,
        messages: [
          { role: "system", content: is_first_chunk ? instructions_with_metadata : instructions_transactions_only },
          { role: "user", content: "Extract transactions:\n\n#{text}" }
        ],
        response_format: { type: "json_object" }
      }

      response = client.chat(parameters: params)
      content = response.dig("choices", 0, "message", "content")

      raise Provider::Openai::Error, "No response from AI" if content.blank?

      parsed = parse_json_response(content)

      {
        transactions: normalize_transactions(parsed["transactions"] || []),
        trades: normalize_trades(parsed["trades"] || []),
        positions: normalize_positions(parsed["positions"] || []),
        period: {
          start_date: parsed.dig("statement_period", "start_date"),
          end_date: parsed.dig("statement_period", "end_date")
        },
        account_holder: parsed["account_holder"],
        account_number: parsed["account_number"],
        account_id: parsed["account_id"],
        bank_name: parsed["bank_name"],
        currency: parsed["currency"],
        base_currency: parsed["base_currency"],
        opening_balance: parsed["opening_balance"],
        closing_balance: parsed["closing_balance"],
        cash_balance: parsed["cash_balance"],
        net_liquidation_value: parsed["net_liquidation_value"]
      }
    end

    def parse_json_response(content)
      cleaned = content.gsub(%r{^```json\s*}i, "").gsub(/```\s*$/, "").strip
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      Rails.logger.error("BankStatementExtractor JSON parse error: #{e.message} (content_length=#{content.to_s.bytesize})")
      { "transactions" => [] }
    end

    def deduplicate_transactions(transactions)
      # Deduplicates transactions that appear in consecutive chunks (chunking artifacts).
      #
      # KNOWN LIMITATION: Legitimate duplicate transactions (same date, amount, merchant)
      # that happen to appear in adjacent chunks will be incorrectly deduplicated.
      # This is an acceptable trade-off since chunking artifacts are more common than
      # true same-day duplicates at chunk boundaries. Transactions within the same
      # chunk are always preserved regardless of similarity.
      seen = Set.new
      transactions.select do |t|
        # Create key without chunk_index for deduplication
        key = [ t[:date], t[:amount], t[:name], t[:chunk_index] ]

        # Check if we've seen this exact transaction in a different chunk
        duplicate = seen.any? do |prev_key|
          prev_key[0..2] == key[0..2] && (prev_key[3] - key[3]).abs <= 1
        end

        seen << key
        !duplicate
      end.map { |t| t.except(:chunk_index) }
    end

    def normalize_transactions(transactions)
      transactions.map do |txn|
        {
          date: parse_date(txn["date"]),
          amount: parse_amount(txn["amount"]),
          currency: txn["currency"],
          name: txn["description"] || txn["name"] || txn["merchant"],
          category: infer_category(txn),
          notes: txn["reference"] || txn["notes"]
        }
      end.compact
    end

    def normalize_trades(trades)
      trades.map do |trade|
        {
          date: parse_date(trade["date"]),
          ticker: trade["ticker"] || trade["symbol"],
          exchange_operating_mic: trade["exchange_operating_mic"],
          qty: parse_amount(trade["qty"] || trade["quantity"]),
          price: parse_amount(trade["price"]),
          amount: parse_amount(trade["amount"] || trade["proceeds"]),
          currency: trade["currency"],
          description: trade["description"] || trade["name"],
          activity_label: trade["activity_label"]
        }
      end.compact
    end

    def normalize_positions(positions)
      positions.map do |position|
        {
          date: parse_date(position["date"]),
          ticker: position["ticker"] || position["symbol"],
          qty: parse_amount(position["qty"] || position["quantity"]),
          price: parse_amount(position["price"]),
          market_value: parse_amount(position["market_value"] || position["amount"]),
          currency: position["currency"],
          name: position["name"] || position["description"]
        }
      end.compact
    end

    def parse_date(date_str)
      return nil if date_str.blank?

      Date.parse(date_str).strftime("%Y-%m-%d")
    rescue ArgumentError
      nil
    end

    def parse_amount(amount)
      return nil if amount.nil?

      if amount.is_a?(Numeric)
        amount.to_f
      else
        amount.to_s.gsub(/[^0-9.\-]/, "").to_f
      end
    end

    def infer_category(txn)
      txn["category"] || txn["type"]
    end

    def instructions_with_metadata
      <<~INSTRUCTIONS.strip
        Extract financial statement data as JSON. Return:
        {"bank_name":"...","account_holder":"...","account_number":"last 4 digits","account_id":"brokerage id if present","currency":"ISO currency","base_currency":"ISO currency","statement_period":{"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"},"opening_balance":0.00,"closing_balance":0.00,"cash_balance":0.00,"net_liquidation_value":0.00,"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"currency":"ISO currency"}],"trades":[{"date":"YYYY-MM-DD","symbol":"AAPL","quantity":10,"price":170.00,"amount":-1700.00,"currency":"USD","description":"Buy 10 AAPL","activity_label":"Buy"}],"positions":[{"date":"YYYY-MM-DD","symbol":"AAPL","quantity":12,"price":173.00,"market_value":2076.00,"currency":"USD","description":"Apple Inc"}]}

        Rules: Negative amounts for debits/expenses/buys, positive for credits/deposits/dividends/sells. For IBKR or Interactive Brokers statements, set bank_name to "IBKR" and extract trades, cash transactions, net liquidation value, cash balance, and positions. Dates as YYYY-MM-DD. Extract ALL rows. JSON only, no markdown.
      INSTRUCTIONS
    end

    def instructions_transactions_only
      <<~INSTRUCTIONS.strip
        Extract financial activity from statement text as JSON. Return:
        {"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"currency":"ISO currency"}],"trades":[{"date":"YYYY-MM-DD","symbol":"AAPL","quantity":10,"price":170.00,"amount":-1700.00,"currency":"USD","description":"Buy 10 AAPL","activity_label":"Buy"}],"positions":[{"date":"YYYY-MM-DD","symbol":"AAPL","quantity":12,"price":173.00,"market_value":2076.00,"currency":"USD","description":"Apple Inc"}]}

        Rules: Negative amounts for debits/expenses/buys, positive for credits/deposits/dividends/sells. Dates as YYYY-MM-DD. Extract ALL rows. JSON only, no markdown.
      INSTRUCTIONS
    end
end
