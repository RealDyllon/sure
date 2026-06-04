module Goals
  class EmergencyFundCalculator
    Result = Data.define(:target_money, :available_money, :progress, :accounts, :review_prompts)

    def initialize(user:, profile:)
      @user = user
      @profile = profile
      @family = user.family
    end

    def call
      classifier = Goals::AccountClassifier.new(user: user, profile: profile).call
      target = monthly_spending * profile.emergency_fund_months
      available, fx_unavailable = sum_balances(classifier.emergency_accounts)

      Result.new(
        target_money: money(target),
        available_money: money(available),
        progress: target.positive? ? available / target : 1.to_d,
        accounts: classifier.emergency_accounts,
        review_prompts: fx_unavailable ? [ :fx_unavailable ] : []
      )
    end

    private
      attr_reader :user, :profile, :family

      def monthly_spending
        profile.annual_spending(inferred: inferred_annual_spending).to_d / 12
      end

      def inferred_annual_spending
        monthly = IncomeStatement.new(family, user: user).avg_expense(interval: "month")
        monthly.to_d * 12
      rescue
        0.to_d
      end

      def sum_balances(accounts)
        fx_unavailable = false
        total = accounts.sum do |account|
          converted_balance(account)
        rescue Money::ConversionError
          fx_unavailable = true
          0.to_d
        end

        [ total, fx_unavailable ]
      end

      def converted_balance(account)
        return account.balance.to_d if account.currency == family.currency

        account.balance_money.exchange_to(family.currency).amount
      end

      def money(amount)
        Money.new(amount, family.currency)
      end
  end
end
