class WiseCard < ApplicationRecord
  include Encryptable

  SENSITIVE_KEYS = %w[pan cvv pin number cardNumber card_number primaryAccountNumber].freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :wise_item

  validates :wise_card_id, uniqueness: { scope: :wise_item_id, allow_nil: true }

  def upsert_wise_snapshot!(card_snapshot)
    snapshot = card_snapshot.with_indifferent_access
    expiry_date = parse_expiry_date(snapshot[:expiryDate] || snapshot[:expiry_date])

    assign_attributes(
      wise_card_id: (snapshot[:token].presence || snapshot[:id]).to_s,
      wise_balance_id: snapshot[:balanceId] || snapshot[:balance_id],
      profile_id: snapshot[:profileId] || snapshot[:profile_id] || wise_item.profile_id,
      name: snapshot[:name].presence || snapshot[:cardHolderName].presence || "#{card_type_from(snapshot).to_s.titleize.presence || 'Wise'} card",
      card_type: card_type_from(snapshot),
      status: status_from(snapshot),
      last_four: snapshot[:lastFour] || snapshot[:lastFourDigits] || snapshot[:last_four],
      expiry_month: snapshot[:expiryMonth] || snapshot.dig(:expiry, :month) || expiry_date&.month,
      expiry_year: snapshot[:expiryYear] || snapshot.dig(:expiry, :year) || expiry_date&.year,
      currency: snapshot[:currency],
      raw_payload: scrub_sensitive(card_snapshot)
    )

    save!
  end

  private

    def scrub_sensitive(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), result|
          next if SENSITIVE_KEYS.include?(key.to_s)
          result[key] = scrub_sensitive(nested)
        end
      when Array
        value.map { |nested| scrub_sensitive(nested) }
      else
        value
      end
    end

    def card_type_from(snapshot)
      snapshot[:type] || snapshot[:cardType] || snapshot.dig(:cardProgram, :type)
    end

    def status_from(snapshot)
      status = snapshot[:status]
      return status[:type] || status[:value] || status[:code] || status.to_json if status.is_a?(Hash)

      status
    end

    def parse_expiry_date(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
end
