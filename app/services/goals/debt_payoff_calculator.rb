module Goals
  class DebtPayoffCalculator
    Result = Data.define(:debt_accounts, :unsupported_accounts, :total_debt_money, :review_prompts)

    def initialize(user:, profile:)
      @user = user
      @profile = profile
      @family = user.family
    end

    def call
      reliable, unsupported = liability_accounts.partition { |account| reliable_debt_account?(account) }

      Result.new(
        debt_accounts: reliable,
        unsupported_accounts: unsupported,
        total_debt_money: money(reliable.sum { |account| converted_balance(account) }),
        review_prompts: unsupported.any? ? [ :unsupported_debt ] : []
      )
    end

    private
      attr_reader :user, :profile, :family

      def liability_accounts
        user.finance_accounts.visible.includes(:accountable).select { |account| account.classification == "liability" }
      end

      def reliable_debt_account?(account)
        return true unless account.accountable_type == "CreditCard"

        available_credit = account.accountable.available_credit
        available_credit.blank? || available_credit.to_d != account.balance.to_d
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
