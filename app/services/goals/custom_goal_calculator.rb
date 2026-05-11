module Goals
  class CustomGoalCalculator
    Result = Data.define(:goal, :available_money, :target_money, :progress, :review_prompts, :fx_unavailable) do
      def fx_unavailable? = fx_unavailable
    end

    def initialize(goal:, user:)
      @goal = goal
      @user = user
    end

    def call
      fx_unavailable = false
      available = funding_accounts.sum do |account|
        convert_account(account)
      rescue Money::ConversionError
        fx_unavailable = true
        0.to_d
      end

      target = goal.target_amount.to_d

      Result.new(
        goal: goal,
        available_money: Money.new(available, goal.target_currency),
        target_money: goal.target_amount_money,
        progress: target.positive? ? available / target : 1.to_d,
        review_prompts: fx_unavailable ? [ :fx_unavailable ] : [],
        fx_unavailable: fx_unavailable
      )
    end

    private
      attr_reader :goal, :user

      def funding_accounts
        ids = goal.funding_account_ids_for(user)
        user.finance_accounts.visible.assets.where(id: ids).to_a
      end

      def convert_account(account)
        return account.balance.to_d if account.currency == goal.target_currency

        account.balance_money.exchange_to(goal.target_currency).amount
      end
  end
end
