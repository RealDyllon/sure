class StatementImportAccount < ApplicationRecord
  belongs_to :statement_import
  belongs_to :account
  validates :source_id, presence: true, uniqueness: { scope: :statement_import_id }
  validate :same_family

  private
    def same_family
      errors.add(:account, :invalid) if account && statement_import && account.family_id != statement_import.family_id
    end
end
