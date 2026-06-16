class WiseConversionIntention < ApplicationRecord
  MIN_PERCENTILE_SAMPLE_COUNT = 5

  belongs_to :family
  belongs_to :source_account, class_name: "Account", optional: true
  has_many :wise_conversion_snapshots, dependent: :destroy

  enum :status, { active: "active", archived: "archived" }, default: :active

  validates :source_currency, :target_currency, presence: true
  validates :target_amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :desired_rate, numericality: { greater_than: 0 }, allow_nil: true
  validate :source_account_belongs_to_family

  before_validation :default_source_currency_from_account
  before_validation :normalize_currencies

  def refresh_snapshot!(observed_on: Date.current, quote_payload: nil)
    current_rate = current_exchange_rate(observed_on)

    wise_conversion_snapshots.create!(
      quote_rate: quote_rate_from(quote_payload),
      quote_fee_amount: quote_fee_amount_from(quote_payload),
      quote_fee_currency: quote_fee_currency_from(quote_payload),
      provider_rate: current_rate,
      provider_name: "exchange_rate",
      rate_30d_percentile: percentile_for(current_rate, observed_on, 30),
      rate_90d_percentile: percentile_for(current_rate, observed_on, 90),
      rate_365d_percentile: percentile_for(current_rate, observed_on, 365),
      observed_on: observed_on,
      raw_quote_payload: quote_payload
    )
  end

  def latest_snapshot
    wise_conversion_snapshots.order(observed_on: :desc, created_at: :desc).first
  end

  def target_status
    rate = latest_snapshot&.provider_rate
    return "tracking" if desired_rate.blank? || rate.blank?
    return "target_met" if rate >= desired_rate
    return "near_target" if rate >= desired_rate * BigDecimal("0.98")

    "below_target"
  end

  def target_status_label
    case target_status
    when "target_met" then "Target met"
    when "near_target" then "Near target"
    when "below_target" then "Below target"
    else "Tracking"
    end
  end

  private

    def default_source_currency_from_account
      self.source_currency ||= source_account&.currency
    end

    def normalize_currencies
      self.source_currency = source_currency.to_s.upcase.presence
      self.target_currency = target_currency.to_s.upcase.presence
    end

    def source_account_belongs_to_family
      return if source_account.blank? || family.blank?
      return if source_account.family_id == family_id

      errors.add(:source_account, "must belong to the same family")
    end

    def current_exchange_rate(observed_on)
      ExchangeRate.find_or_fetch_rate(
        from: source_currency,
        to: target_currency,
        date: observed_on,
        cache: true
      )&.rate
    rescue => e
      Rails.logger.warn("WiseConversionIntention: exchange rate lookup failed for #{source_currency}->#{target_currency} on #{observed_on}: #{e.class} - #{e.message}")
      nil
    end

    def percentile_for(current_rate, observed_on, days)
      return nil if current_rate.blank?

      rates = ExchangeRate.where(
        from_currency: source_currency,
        to_currency: target_currency,
        date: (observed_on - days.days)..observed_on
      ).pluck(:rate)
      return nil if rates.size < MIN_PERCENTILE_SAMPLE_COUNT

      ((rates.count { |rate| rate <= current_rate } / rates.count.to_d) * 100).round(2)
    end

    def quote_rate_from(quote_payload)
      return nil unless quote_payload.is_a?(Hash)

      data = quote_payload.with_indifferent_access
      data[:rate] || data[:exchangeRate] || data.dig(:paymentOptions, 0, :rate)
    end

    def quote_fee_amount_from(quote_payload)
      return nil unless quote_payload.is_a?(Hash)

      data = quote_payload.with_indifferent_access
      data[:fee] || data.dig(:paymentOptions, 0, :fee, :total)
    end

    def quote_fee_currency_from(quote_payload)
      return nil unless quote_payload.is_a?(Hash)

      data = quote_payload.with_indifferent_access
      data[:feeCurrency] || data.dig(:paymentOptions, 0, :fee, :currency)
    end
end
