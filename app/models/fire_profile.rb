class FireProfile < ApplicationRecord
  FIRE_ROLES = %w[bridge later srs_later excluded].freeze
  belongs_to :family
  belongs_to :user
  validates :user_id, uniqueness: { scope: :family_id }
  validates :planning_region, inclusion: { in: %w[generic singapore] }
  validates :withdrawal_rate, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :expected_return, :inflation_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :annual_spending_override, :annual_contribution, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :cpf_access_age, :cpf_life_age, :srs_access_age, numericality: { only_integer: true, greater_than: 0, less_than: 150 }
  validates :current_age, numericality: { only_integer: true, greater_than: 0, less_than: 150 }, allow_nil: true
  validate :user_belongs_to_family
  before_validation :normalize_rates

  def self.for_user!(user)
    find_or_create_by!(user: user, family: user.family) do |profile|
      profile.planning_region = user.family.country == "SG" || user.family.currency == "SGD" ? "singapore" : "generic"
    end
  end

  def singapore? = planning_region == "singapore"
  def birth_year = nil
  def annual_spending(inferred:) = annual_spending_override || inferred
  def prompt_skipped?(_key) = false

  def fire_role_overrides
    ids = user.finance_accounts.visible.where(family_id: family_id).pluck(:id)
    account_role_overrides.to_h.select { |id, role| ids.include?(id) && FIRE_ROLES.include?(role) }
  end

  def set_fire_role!(account, role, user:)
    raise ArgumentError unless user.id == user_id && user.finance_accounts.visible.exists?(id: account.id) && FIRE_ROLES.include?(role)
    update!(account_role_overrides: fire_role_overrides.merge(account.id => role))
  end

  private
    def normalize_rates
      %i[withdrawal_rate expected_return inflation_rate].each do |field|
        value = self[field]
        self[field] = value / 100 if value && value > 1 && value <= 100
      end
      self.annual_contribution ||= 0
    end

    def user_belongs_to_family
      errors.add(:user, :invalid) if user && user.family_id != family_id
    end
end
