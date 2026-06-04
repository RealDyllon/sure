require "digest/md5"

class WiseEntry::Processor
  include CurrencyNormalizable

  def initialize(wise_transaction, wise_balance:)
    @wise_transaction = wise_transaction
    @wise_balance = wise_balance
  end

  def process
    return nil unless account.present?

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "wise",
      notes: notes,
      extra: extra_metadata
    )
  end

  private

    attr_reader :wise_transaction, :wise_balance

    def data
      @data ||= wise_transaction.with_indifferent_access
    end

    def details
      @details ||= data[:details].is_a?(Hash) ? data[:details].with_indifferent_access : {}.with_indifferent_access
    end

    def account
      @account ||= wise_balance.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def external_id
      @external_id ||= begin
        upstream_id = data[:id].presence || data[:referenceNumber].presence || data[:transactionId].presence ||
                      details[:id].presence || content_hash
        "wise_#{wise_balance.balance_id}_#{upstream_id}"
      end
    end

    def content_hash
      Digest::MD5.hexdigest([ raw_amount, raw_currency, raw_date, name, data[:type] ].join("|"))
    end

    def amount
      -raw_amount
    end

    def raw_amount
      @raw_amount ||= begin
        value = if data[:amount].is_a?(Hash)
          data.dig(:amount, :value)
        else
          data[:amount] || data[:value]
        end
        BigDecimal(value.to_s)
      end
    end

    def currency
      parse_currency(raw_currency) || wise_balance.currency || account.currency
    end

    def raw_currency
      data.dig(:amount, :currency) || data[:currency] || wise_balance.currency
    end

    def date
      raw = raw_date
      case raw
      when Date
        raw
      when Time, DateTime
        raw.to_date
      when Integer, Float
        Time.at(raw).to_date
      else
        Time.zone.parse(raw.to_s).to_date
      end
    rescue ArgumentError, TypeError
      raise ArgumentError, "Unable to parse Wise transaction date: #{raw.inspect}"
    end

    def raw_date
      data[:date] || data[:timestamp] || data[:createdOn] || data[:createdAt]
    end

    def name
      details[:description].presence ||
        details[:merchantName].presence ||
        details.dig(:merchant, :name).presence ||
        data[:description].presence ||
        data[:type].to_s.humanize.presence ||
        "Wise transaction"
    end

    def notes
      details[:reference].presence || details[:senderName].presence || details[:recipientName].presence
    end

    def extra_metadata
      {
        wise: {
          balance_id: wise_balance.balance_id,
          statement_reference: data[:referenceNumber] || data[:reference],
          transaction_type: data[:type],
          card_id: details[:cardId] || details[:card_id],
          card_last_four: details[:cardLastFourDigits] || details[:cardLastFour] || details[:lastFour],
          exchange_rate: details[:exchangeRate] || data[:exchangeRate],
          source_amount: details[:sourceAmount] || data[:sourceAmount],
          target_amount: details[:targetAmount] || data[:targetAmount]
        }.compact
      }
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid Wise transaction currency '#{currency_value}' for #{external_id}")
    end
end
