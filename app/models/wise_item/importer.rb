require "digest/md5"

class WiseItem::Importer
  MAX_STATEMENT_DAYS = 469

  attr_reader :wise_item, :wise_provider

  def initialize(wise_item, wise_provider:)
    @wise_item = wise_item
    @wise_provider = wise_provider
  end

  def import
    @wise_provider = wise_item.wise_provider if wise_item.refresh_access_token_if_needed!

    import_profiles
    import_balances
    import_cards
    import_linked_balance_statements
    update_setup_state

    {
      success: true,
      balances: wise_item.wise_balances.count,
      cards: wise_item.wise_cards.count
    }
  rescue Provider::Wise::WiseError => e
    wise_item.update!(status: :requires_update) if e.error_type.in?(%i[unauthorized access_forbidden])
    raise
  end

  private

    def import_profiles
      profiles = normalize_collection(wise_provider.get_profiles)
      wise_item.upsert_wise_snapshot!(profiles)
    end

    def import_balances
      balances = normalize_collection(wise_provider.get_balances(profile_id: wise_item.profile_id))
      balances.each do |balance_data|
        data = balance_data.with_indifferent_access
        next unless data[:type].to_s == "STANDARD"
        next if data[:id].blank?

        wise_balance = wise_item.wise_balances.find_or_initialize_by(balance_id: data[:id].to_s)
        wise_balance.upsert_wise_snapshot!(data)
      end
    end

    def import_cards
      normalize_collection(wise_provider.get_cards(profile_id: wise_item.profile_id)).each do |card_data|
        data = card_data.with_indifferent_access
        card_id = data[:token].presence || data[:id].presence
        next if card_id.blank?

        wise_card = wise_item.wise_cards.find_or_initialize_by(wise_card_id: card_id.to_s)
        wise_card.upsert_wise_snapshot!(data)
      end
    rescue Provider::Wise::WiseError => e
      Rails.logger.warn("WiseItem::Importer - card import skipped: #{e.class} - #{e.message}")
    end

    def import_linked_balance_statements
      wise_item.wise_balances.joins(:account_provider).find_each do |wise_balance|
        transactions = wise_balance.raw_transactions_payload.to_a
        existing_keys = transactions.map { |txn| transaction_key(txn) }.to_set

        statement_chunks(start_date: sync_start_date, end_date: Date.current).each do |chunk_start, chunk_end|
          statement = wise_provider.get_balance_statement(
            profile_id: wise_balance.profile_id.presence || wise_item.profile_id,
            balance_id: wise_balance.balance_id,
            currency: wise_balance.currency,
            interval_start: chunk_start.beginning_of_day.iso8601,
            interval_end: chunk_end.end_of_day.iso8601
          )

          extract_transactions(statement).each do |transaction|
            key = transaction_key(transaction)
            next if existing_keys.include?(key)

            transactions << transaction
            existing_keys << key
          end
        end

        wise_balance.upsert_wise_transactions_snapshot!(transactions)
      end
    end

    def update_setup_state
      wise_item.update!(
        pending_account_setup: wise_item.wise_balances.requires_setup.exists?,
        status: :good
      )
    end

    def sync_start_date
      wise_item.sync_start_date || 90.days.ago.to_date
    end

    def statement_chunks(start_date:, end_date:)
      chunks = []
      chunk_start = start_date.to_date
      final_date = end_date.to_date

      while chunk_start <= final_date
        chunk_end = [ chunk_start + (MAX_STATEMENT_DAYS - 1).days, final_date ].min
        chunks << [ chunk_start, chunk_end ]
        chunk_start = chunk_end + 1.day
      end

      chunks
    end

    def normalize_collection(payload)
      case payload
      when Array
        payload
      when Hash
        data = payload.with_indifferent_access
        data[:balances] || data[:cards] || data[:profiles] || data[:data] || []
      else
        []
      end
    end

    def extract_transactions(statement)
      data = statement.with_indifferent_access
      data[:transactions] || data.dig(:statement, :transactions) || data.dig(:data, :transactions) || []
    end

    def transaction_key(transaction)
      data = transaction.with_indifferent_access
      data[:id].presence || data[:referenceNumber].presence || data[:transactionId].presence ||
        Digest::MD5.hexdigest(data.to_json)
    end
end
