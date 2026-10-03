class StatementProfile < ApplicationRecord
  PROVIDERS = %w[dbs paylah uob cpf ibkr].freeze

  belongs_to :family
  belongs_to :account

  validates :provider, inclusion: { in: PROVIDERS }
  validates :source_id, :account_type, :currency, presence: true
  validates :source_id, uniqueness: { scope: [ :family_id, :provider ] }
  validate :account_belongs_to_family
  validate :account_type_is_supported

  private

    def account_belongs_to_family
      return if account.nil? || family.nil? || account.family_id == family_id

      errors.add(:account, "must belong to family")
    end

    def account_type_is_supported
      return if Accountable::TYPES.include?(account_type)

      errors.add(:account_type, "is not supported")
    end
end
