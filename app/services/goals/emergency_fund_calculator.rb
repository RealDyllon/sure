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
      available = classifier.emergency_accounts.sum { |account| converted_balance(account) }

      Result.new(
        target_money: money(target),
        available_money: money(available),
        progress: target.positive? ? available / target : 1.to_d,
        accounts: classifier.emergency_accounts,
        review_prompts: []
      )
    end

    private
      attr_reader :user, :profile, :family

      def monthly_spending
        profile.annual_spending(inferred: 0).to_d / 12
      end

      def converted_balance(account)
        return account.balance.to_d if account.currency == family.currency

        account.balance_money.exchange_to(family.currency).amount
      rescue Money::ConversionError
        0.to_d
      end

      def money(amount)
        Money.new(amount, family.currency)
      end
  end
end
