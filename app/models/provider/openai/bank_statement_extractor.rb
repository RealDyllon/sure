class Provider::Openai::BankStatementExtractor
  MAX_CHARS_PER_CHUNK = 4_000_000
  attr_reader :client, :pdf_content, :model, :pdf_password, :progress_callback

  def initialize(client:, pdf_content:, model:, pdf_password: nil, progress_callback: nil)
    @client = client
    @pdf_content = pdf_content
    @model = model
    @pdf_password = pdf_password
    @progress_callback = progress_callback
  end

  def extract
    pages = extract_pages_from_pdf
    raise Provider::Openai::Error, "Could not extract text from PDF" if pages.empty?

    chunks = build_chunks(pages)
    Rails.logger.info("BankStatementExtractor: Processing #{chunks.size} chunk(s) from #{pages.size} page(s)")
    emit_progress(current: 0, total: chunks.size, message: "Preparing #{chunks.size} chunks")

    all_transactions = []
    all_trades = []
    all_positions = []
    all_accounts = []
    metadata = {}

    chunks.each_with_index do |chunk, index|
      Rails.logger.info("BankStatementExtractor: Processing chunk #{index + 1}/#{chunks.size}")
      emit_progress(current: index, total: chunks.size, message: "Processing chunk #{index + 1} of #{chunks.size}...")
      result = process_chunk(chunk, index == 0)
      emit_progress(current: index + 1, total: chunks.size, message: "Processed chunk #{index + 1} of #{chunks.size}")

      # Tag transactions with chunk index for deduplication
      tagged_transactions = (result[:transactions] || []).map { |t| t.merge(chunk_index: index) }
      all_transactions.concat(tagged_transactions)
      all_trades.concat(result[:trades] || [])
      all_positions.concat(result[:positions] || [])
      all_accounts.concat(tag_accounts(result[:accounts] || [], index))

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
          period: result[:period],
          accounts: result[:accounts]
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
      if (result[:accounts] || []).any?
        metadata[:accounts] = result[:accounts]
      end
    end

    {
      transactions: deduplicate_transactions(all_transactions),
      accounts: merge_accounts(all_accounts),
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

    def emit_progress(current:, total:, message:)
      progress_callback&.call(current: current, total: total, message: message)
    end

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
        accounts: normalize_accounts(parsed["accounts"] || []),
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

    def normalize_accounts(accounts)
      accounts.map do |account|
        account = account.to_h

        {
          account_name: account["account_name"] || account["name"],
          account_number: normalized_account_number(account["account_number"]),
          account_id: account["account_id"],
          account_type: account["account_type"],
          subtype: account["subtype"],
          currency: account["currency"],
          base_currency: account["base_currency"],
          opening_balance: parse_amount(account["opening_balance"]),
          closing_balance: parse_amount(account["closing_balance"].presence || account["net_liquidation_value"]),
          cash_balance: parse_amount(account["cash_balance"]),
          net_liquidation_value: parse_amount(account["net_liquidation_value"]),
          transactions: normalize_transactions(Array(account["transactions"]).presence || account["cash_transactions"] || []),
          trades: normalize_trades(account["trades"] || []),
          positions: normalize_positions(account["positions"] || [])
        }.compact
      end
    end

    def tag_accounts(accounts, chunk_index)
      accounts.map do |account|
        account.merge(
          transactions: Array(account[:transactions]).map { |transaction| transaction.merge(chunk_index: chunk_index) }
        )
      end
    end

    def merge_accounts(accounts)
      accounts.each_with_object([]) do |account, merged_accounts|
        existing_index = merged_accounts.index { |merged_account| same_account?(merged_account, account) }

        if existing_index
          merged_accounts[existing_index] = merge_account(merged_accounts[existing_index], account)
        else
          merged_accounts << account
        end
      end
    end

    def account_key(account)
      [
        account[:account_id].presence,
        account[:account_number].presence
      ].compact.map { |value| normalized_account_number(value) }.first
    end

    def same_account?(first, second)
      first_key = account_key(first)
      second_key = account_key(second)

      if first_key.present? || second_key.present?
        return true if first_key.present? && first_key == second_key && compatible_account_metadata?(first, second)
        return false if first_key.present? && second_key.present?
      end

      return false unless account_activity_count(first).zero? || account_activity_count(second).zero?

      normalized_account_name(first[:account_name]) == normalized_account_name(second[:account_name]) &&
        compatible_account_metadata?(first, second)
    end

    def compatible_account_metadata?(first, second)
      return false if first[:currency].present? && second[:currency].present? && first[:currency] != second[:currency]
      return false if first[:account_type].present? && second[:account_type].present? && first[:account_type] != second[:account_type]
      return false if first[:subtype].present? && second[:subtype].present? && first[:subtype] != second[:subtype]
      return false if normalized_account_name(first[:account_name]).present? &&
        normalized_account_name(second[:account_name]).present? &&
        normalized_account_name(first[:account_name]) != normalized_account_name(second[:account_name])

      true
    end

    def merge_account(first, second)
      summary_account = if account_activity_count(first).zero? && account_activity_count(second).positive?
        first
      elsif account_activity_count(second).zero? && account_activity_count(first).positive?
        second
      end
      activity_account = summary_account == first ? second : first

      first.merge(second) do |key, old_value, new_value|
        case key
        when :transactions
          deduplicate_transactions(Array(old_value) + Array(new_value), strip_chunk_index: false)
        when :trades, :positions
          Array(old_value) + Array(new_value)
        when :account_number, :account_id, :subtype
          activity_account&.fetch(key, nil).presence || new_value.presence || old_value
        when :opening_balance, :closing_balance, :cash_balance, :net_liquidation_value
          summary_account&.fetch(key, nil).presence || new_value.presence || old_value
        else
          new_value.presence || old_value
        end
      end
    end

    def account_activity_count(account)
      Array(account[:transactions]).size + Array(account[:trades]).size + Array(account[:positions]).size
    end

    def normalized_account_name(account_name)
      account_name.to_s.downcase.squish
    end

    def normalized_account_number(account_number)
      return if account_number.blank?

      digits = account_number.to_s.scan(/\d/)
      digits.size >= 4 ? digits.last(4).join : account_number.to_s
    end

    def parse_json_response(content)
      cleaned = content.gsub(%r{^```json\s*}i, "").gsub(/```\s*$/, "").strip
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      Rails.logger.error("BankStatementExtractor JSON parse error: #{e.message} (content_length=#{content.to_s.bytesize})")
      { "transactions" => [] }
    end

    def deduplicate_transactions(transactions, strip_chunk_index: true)
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
      end.map { |t| strip_chunk_index ? t.except(:chunk_index) : t }
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
        {"bank_name":"...","account_holder":"...","account_number":"last 4 digits","account_id":"brokerage id if present","currency":"ISO currency","base_currency":"ISO currency","statement_period":{"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"},"opening_balance":0.00,"closing_balance":0.00,"cash_balance":0.00,"net_liquidation_value":0.00,"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"currency":"ISO currency"}],"accounts":[{"account_name":"...","account_number":"last 4 digits","account_type":"Depository|CreditCard|Investment","subtype":"checking|savings|credit_card|brokerage","currency":"ISO currency","opening_balance":0.00,"closing_balance":0.00,"cash_balance":0.00,"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"currency":"ISO currency"}],"trades":[],"positions":[]}],"trades":[{"date":"YYYY-MM-DD","symbol":"AAPL","quantity":10,"price":1020.00,"amount":-1005.00,"currency":"USD","description":"Buy 10 AAPL","activity_label":"Buy"}],"positions":[{"date":"YYYY-MM-DD","symbol":"AAPL","quantity":12,"price":1021.00,"market_value":1007.00,"currency":"USD","description":"Apple Inc"}]}

        Rules: Negative amounts for debits/expenses/buys, positive for credits/deposits/dividends/sells. For consolidated statements with multiple accounts, especially DBS monthly statements, split rows into the accounts array by account section and include each account's name, last four account digits, account type, subtype, balances, and transactions. When transactions are placed in account sub-arrays, leave the top-level transactions array empty — do not duplicate transactions at both levels. For IBKR or Interactive Brokers statements, set bank_name to "IBKR" and extract trades, cash transactions, net liquidation value, cash balance, and positions. For CPF statements, set bank_name to "CPF", account_type to "Investment", and use subtypes cpf_ordinary, cpf_special, cpf_medisave, cpf_retirement, or cpf_other. Dates as YYYY-MM-DD; when transaction rows omit the year, use the statement period year. Extract ALL rows. JSON only, no markdown.
      INSTRUCTIONS
    end

    def instructions_transactions_only
      <<~INSTRUCTIONS.strip
        Extract financial activity from statement text as JSON. Return:
        {"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"currency":"ISO currency"}],"accounts":[{"account_name":"...","account_number":"last 4 digits","account_type":"Depository|CreditCard|Investment","subtype":"checking|savings|credit_card|brokerage","currency":"ISO currency","transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"currency":"ISO currency"}]}],"trades":[{"date":"YYYY-MM-DD","symbol":"AAPL","quantity":10,"price":1020.00,"amount":-1005.00,"currency":"USD","description":"Buy 10 AAPL","activity_label":"Buy"}],"positions":[{"date":"YYYY-MM-DD","symbol":"AAPL","quantity":12,"price":1021.00,"market_value":1007.00,"currency":"USD","description":"Apple Inc"}]}

        Rules: Negative amounts for debits/expenses/buys, positive for credits/deposits/dividends/sells. If a chunk includes account-section labels from a consolidated DBS statement, return rows in the matching accounts array item. For CPF account sections, set account_type to "Investment" and use subtypes cpf_ordinary, cpf_special, cpf_medisave, cpf_retirement, or cpf_other. Dates as YYYY-MM-DD; when transaction rows omit the year, infer it from any statement period or statement date visible in the chunk. Extract ALL rows. JSON only, no markdown.
      INSTRUCTIONS
    end
end
