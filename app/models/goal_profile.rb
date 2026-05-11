class GoalProfile < ApplicationRecord
  PLANNING_REGIONS = %w[generic singapore].freeze
  FIRE_ROLES = %w[bridge later excluded].freeze
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  belongs_to :family
  belongs_to :user

  validates :planning_region, inclusion: { in: PLANNING_REGIONS }, allow_blank: true
  validates :withdrawal_rate, numericality: { greater_than: 0 }
  validates :expected_return, :inflation_rate, numericality: true
  validates :emergency_fund_months, :cpf_access_age, :cpf_life_age, :srs_access_age,
    numericality: { only_integer: true, greater_than: 0 }
  validates :current_age, numericality: { only_integer: true, greater_than: 0 }, allow_blank: true
  validates :birth_year, numericality: { only_integer: true, greater_than: 1900 }, allow_blank: true

  before_validation :normalize_percentage_fields

  class << self
    def find_or_create_for!(user)
      find_or_create_by!(family: user.family, user: user)
    end
  end

  def planning_region
    self[:planning_region].presence || inferred_planning_region
  end

  def singapore?
    planning_region == "singapore"
  end

  def inferred_planning_region
    return "singapore" if family.country == "SG"
    return "singapore" if family.currency == "SGD"
    return "singapore" if cpf_account_detected?

    "generic"
  end

  def skip_prompt!(key)
    prompts = (skipped_prompts + [ key.to_s ]).uniq
    update!(skipped_prompts: prompts)
  end

  def prompt_skipped?(key)
    skipped_prompts.include?(key.to_s)
  end

  def annual_spending(inferred:)
    annual_spending_override.presence || inferred
  end

  def reset_assumption!(name)
    case name.to_sym
    when :annual_spending
      update!(annual_spending_override: nil)
    else
      raise ArgumentError, "Unknown assumption: #{name}"
    end
  end

  def fire_role_overrides
    valid_ids = valid_finance_account_ids(user).to_set
    raw_fire_roles.each_with_object({}) do |(account_id, role), roles|
      next unless valid_ids.include?(account_id)
      next unless FIRE_ROLES.include?(role)

      roles[account_id] = role
    end
  end

  def emergency_account_ids
    valid_ids = valid_finance_account_ids(user).to_set
    raw_emergency_account_ids.select { |account_id| valid_ids.include?(account_id) }
  end

  def update_account_role_overrides!(user:, fire_roles:, emergency_account_ids:)
    valid_ids = valid_finance_account_ids(user).to_set

    clean_fire_roles = normalize_roles(fire_roles).each_with_object({}) do |(account_id, role), roles|
      account_id = account_id.to_s
      role = role.to_s
      next unless valid_ids.include?(account_id)
      next unless FIRE_ROLES.include?(role)

      roles[account_id] = role
    end

    clean_emergency_ids = normalize_ids(emergency_account_ids).select { |account_id| valid_ids.include?(account_id) }

    update!(
      account_role_overrides: {
        "fire_roles" => clean_fire_roles,
        "emergency_account_ids" => clean_emergency_ids
      }
    )
  end

  def set_fire_role!(account, role, user:)
    roles = fire_role_overrides.merge(account.id => role.to_s)
    update_account_role_overrides!(user: user, fire_roles: roles, emergency_account_ids: emergency_account_ids)
  end

  def set_emergency_included_account_ids!(account_ids, user:)
    update_account_role_overrides!(user: user, fire_roles: fire_role_overrides, emergency_account_ids: account_ids)
  end

  def valid_finance_account_ids(account_user, account_ids = nil)
    scope = account_user.finance_accounts.visible.where(family_id: family_id)
    scope = scope.where(id: normalize_ids(account_ids)) if account_ids
    scope.pluck(:id).map(&:to_s)
  end

  private
    def raw_fire_roles
      account_role_overrides.fetch("fire_roles", {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
    end

    def normalize_roles(roles)
      roles = roles.to_unsafe_h if roles.respond_to?(:to_unsafe_h)
      roles = roles.to_h if roles.respond_to?(:to_h)
      roles.is_a?(Hash) ? roles : {}
    end

    def raw_emergency_account_ids
      normalize_ids(account_role_overrides.fetch("emergency_account_ids", []))
    end

    def normalize_ids(ids)
      Array(ids).filter_map do |id|
        id = id.to_s
        id if id.match?(UUID_PATTERN)
      end.uniq
    end

    def cpf_account_detected?
      user.finance_accounts.visible.where(family_id: family_id).includes(:accountable).any? do |account|
        account.accountable_type == "Investment" && account.subtype.to_s.start_with?("cpf_")
      end
    end

    def normalize_percentage_fields
      %i[withdrawal_rate expected_return inflation_rate savings_rate_target].each do |field|
        value = self[field]
        next if value.blank?
        next unless value > 1 && value <= 100

        self[field] = value / 100
      end
    end
end
