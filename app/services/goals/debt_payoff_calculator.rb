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
      total_debt, fx_unavailable = sum_balances(reliable)
      prompts = []
      prompts << :unsupported_debt if unsupported.any?
      prompts << :fx_unavailable if fx_unavailable

      Result.new(
        debt_accounts: reliable,
        unsupported_accounts: unsupported,
        total_debt_money: money(total_debt),
        review_prompts: prompts
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
