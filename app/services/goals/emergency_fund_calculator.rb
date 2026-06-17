module Goals
  class EmergencyFundCalculator
    Result = Data.define(:target_money, :available_money, :current_months, :progress, :accounts, :review_prompts)

    def initialize(user:, profile:, classifier: nil)
      @user = user
      @profile = profile
      @family = user.family
      @classifier = classifier
    end

    def call
      classifier = self.classifier
      monthly = monthly_spending
      target = monthly * profile.emergency_fund_months
      available, fx_unavailable = sum_balances(classifier.emergency_accounts)

      Result.new(
        target_money: money(target),
        available_money: money(available),
        current_months: current_months(monthly, available),
        progress: target.positive? ? available / target : 1.to_d,
        accounts: classifier.emergency_accounts,
        review_prompts: fx_unavailable ? [ :fx_unavailable ] : []
      )
    end

    private
      attr_reader :user, :profile, :family

      def classifier
        @classifier ||= Goals::AccountClassifier.new(user: user, profile: profile).call
      end

      def monthly_spending
        profile.annual_spending(inferred: inferred_annual_spending).to_d / 12
      end

      def current_months(monthly, available)
        return nil if monthly.to_d.zero?

        (available.to_d / monthly.to_d).round(1)
      end

      def inferred_annual_spending
        monthly = IncomeStatement.new(family, user: user).avg_expense(interval: "month")
        monthly.to_d * 12
      rescue StandardError
        # IncomeStatement#avg_expense returns 0 when there is no data, so this only guards
        # against unexpected errors (e.g., a future refactor that raises). Narrow rescue
        # avoids masking real bugs as "no spending data".
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
