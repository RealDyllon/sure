class GoalProfile < ApplicationRecord
  PLANNING_REGIONS = %w[generic singapore].freeze
  FIRE_ROLES = %w[bridge later srs_later excluded].freeze
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  belongs_to :family
  belongs_to :user

  validates :planning_region, inclusion: { in: PLANNING_REGIONS }, allow_blank: true
  validates :withdrawal_rate, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :expected_return, :inflation_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :savings_rate_target, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_blank: true
  validates :annual_spending_override, numericality: { greater_than_or_equal_to: 0 }, allow_blank: true
  validates :annual_contribution, numericality: { greater_than_or_equal_to: 0 }, allow_blank: true
  validates :emergency_fund_months, :cpf_access_age, :cpf_life_age, :srs_access_age,
    numericality: { only_integer: true, greater_than: 0 }
  validates :current_age, numericality: { only_integer: true, greater_than: 0, less_than: 150 }, allow_blank: true
  validates :birth_year, numericality: { only_integer: true, greater_than: 1900, less_than_or_equal_to: ->(_profile) { Date.current.year } }, allow_blank: true

  before_validation :normalize_blank_planning_region
  before_validation :normalize_percentage_fields
  before_validation :normalize_blank_numeric_fields

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

  def emergency_account_ids_overridden?
    account_role_overrides.key?("emergency_account_ids")
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
      # Treat any value in the inclusive range (1, 100] as a whole-number percentage
      # (4 -> 0.04, 100 -> 1.0). Values <= 1 are kept as decimal fractions (0.04, 0.5).
      # Values > 100 are rejected by the numericality validator rather than silently
      # scaled, so 150 fails rather than becoming 1.5. The "1.5 -> 0.015" mapping is
      # intentional: a percentage-form input is the safer interpretation for rates that
      # are economically bounded well below 1.
      %i[withdrawal_rate expected_return inflation_rate savings_rate_target].each do |field|
        value = self[field]
        next if value.blank?
        next unless value > 1 && value <= 100

        self[field] = value / 100
      end
    end

    def normalize_blank_planning_region
      self.planning_region = nil if self[:planning_region].blank?
    end

    # Centralizes the "blank form field maps to a sensible default" rule for
    # numeric columns. We can't just rely on `allow_blank: true` because the
    # columns are NOT NULL: a blank value passes validation (the validator
    # short-circuits on blank) but crashes the DB write. Without this callback,
    # every controller that persists these fields has to repeat the coercion
    # — and a future third write path (console, import, API) could silently
    # regress. Scoped to only the columns whose DB default matches the
    # desired blank-target.
    def normalize_blank_numeric_fields
      # ActiveRecord coerces an empty string to nil when assigning to a
      # numeric column, so we have to check both nil and the original blank
      # form. `assign_attributes(annual_contribution: "")` leaves the
      # in-memory attribute as nil before validation runs.
      if annual_contribution.nil?
        self.annual_contribution = 0
      end
    end
end
