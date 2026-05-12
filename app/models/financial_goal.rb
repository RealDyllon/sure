class FinancialGoal < ApplicationRecord
  UUID_PATTERN = GoalProfile::UUID_PATTERN
  GOAL_TYPES = %w[custom].freeze

  belongs_to :family
  belongs_to :user
  has_many :financial_goal_funding_accounts, dependent: :destroy
  has_many :funding_accounts, through: :financial_goal_funding_accounts, source: :account

  enum :status, { active: "active", archived: "archived" }, validate: true

  before_validation :normalize_target_currency

  validates :goal_type, presence: true, inclusion: { in: GOAL_TYPES }
  validates :name, :target_amount, :target_currency, presence: true, if: :custom?
  validates :target_amount, numericality: { greater_than: 0 }, allow_blank: true
  validate :target_currency_supported, if: -> { custom? && target_currency.present? }

  scope :custom, -> { where(goal_type: "custom") }
  scope :ordered, -> { order(:position, :created_at, :id) }

  def custom?
    goal_type == "custom"
  end

  def target_amount_money
    return nil if target_amount.blank? || target_currency.blank?

    Money.new(target_amount, target_currency)
  end

  def archive!
    update!(status: "archived")
  end

  def set_funding_account_ids!(user:, account_ids:)
    valid_ids = valid_finance_account_ids(user, account_ids)

    transaction do
      financial_goal_funding_accounts.destroy_all
      valid_ids.each do |account_id|
        financial_goal_funding_accounts.create!(account_id: account_id)
      end
    end
  end

  def funding_account_ids_for(user)
    valid_ids = valid_finance_account_ids(user).to_set

    financial_goal_funding_accounts.includes(:account).filter_map do |mapping|
      account_id = mapping.account_id&.to_s
      account_id if account_id && valid_ids.include?(account_id)
    end
  end

  def valid_finance_account_ids(account_user, account_ids = nil)
    scope = account_user.finance_accounts.visible.assets.where(family_id: family_id)
    scope = scope.where(id: normalize_ids(account_ids)) if account_ids
    scope.pluck(:id).map(&:to_s)
  end

  private
    def normalize_target_currency
      self.target_currency = target_currency.to_s.strip.upcase if target_currency.present?
    end

    def target_currency_supported
      Money::Currency.new(target_currency)
    rescue Money::Currency::UnknownCurrencyError
      errors.add(:target_currency, "is not supported")
    end

    def normalize_ids(ids)
      Array(ids).filter_map do |id|
        id = id.to_s
        id if id.match?(UUID_PATTERN)
      end.uniq
    end
end
