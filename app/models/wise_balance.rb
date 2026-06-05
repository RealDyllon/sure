class WiseBalance < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    encrypts :extra
  end

  belongs_to :wise_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :currency, :balance_type, presence: true
  validates :balance_id, uniqueness: { scope: :wise_item_id, allow_nil: true }

  scope :not_skipped, -> { where(skipped: false) }
  scope :requires_setup, -> { not_skipped.left_joins(:account_provider).where(account_providers: { id: nil }) }

  def current_account
    account
  end

  def skipped?
    skipped
  end

  def mark_skipped!
    update!(skipped: true)
  end

  def clear_skipped!
    update!(skipped: false) if skipped?
  end

  def ensure_account_provider!
    return nil unless current_account

    AccountProvider.find_or_initialize_by(provider: self).tap do |provider_link|
      provider_link.account = current_account
      provider_link.save!
    end
  end

  def upsert_wise_snapshot!(balance_snapshot)
    snapshot = balance_snapshot.with_indifferent_access
    currency_code = parse_currency(snapshot[:currency] || snapshot.dig(:amount, :currency) || snapshot.dig(:cashAmount, :currency))
    current = parse_decimal(snapshot.dig(:cashAmount, :value) || snapshot[:cashAmount] || snapshot.dig(:amount, :value) || snapshot[:amount])
    available = parse_decimal(snapshot.dig(:amount, :value) || snapshot[:amount])

    assign_attributes(
      balance_id: snapshot[:id].to_s,
      profile_id: snapshot[:profileId] || snapshot[:profile_id] || wise_item.profile_id,
      name: snapshot[:name].presence || "Wise #{currency_code}",
      currency: currency_code,
      balance_type: snapshot[:type].presence || "STANDARD",
      account_status: snapshot[:state] || snapshot[:status],
      current_balance: current,
      available_balance: available,
      institution_metadata: { name: "Wise", domain: "wise.com", color: "#00B9FF" },
      raw_payload: balance_snapshot
    )

    save!
  end

  def upsert_wise_transactions_snapshot!(transactions_snapshot)
    assign_attributes(raw_transactions_payload: transactions_snapshot)
    save!
  end

  private

    def parse_decimal(value)
      return nil if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid Wise currency '#{currency_value}' for balance #{id}")
    end
end
