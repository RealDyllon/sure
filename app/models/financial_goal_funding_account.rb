class FinancialGoalFundingAccount < ApplicationRecord
  belongs_to :financial_goal
  belongs_to :account, optional: true
end
