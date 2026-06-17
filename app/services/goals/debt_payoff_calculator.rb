module Goals
  class DebtPayoffCalculator
    Result = Data.define(
      :debt_accounts,
      :unsupported_accounts,
      :total_debt_money,
      :monthly_payment_money,
      :estimated_months,
      :has_payment_info,
      :review_prompts
    ) do
      def has_payment_info? = has_payment_info
    end

    def initialize(user:, profile:)
      @user = user
      @profile = profile
      @family = user.family
    end

    def call
      reliable, unsupported = liability_accounts.partition { |account| reliable_debt_account?(account) }
      total_debt, debt_fx_unavailable = sum_balances(reliable)
      monthly_payments, payment_fx_unavailable, payments_missing = aggregate_payments(reliable)
      fx_unavailable = debt_fx_unavailable || payment_fx_unavailable
      has_payment_info = !fx_unavailable && !payments_missing && reliable.any?

      estimated_months = if has_payment_info && monthly_payments.positive?
        (total_debt / monthly_payments).ceil
      end

      prompts = []
      prompts << :unsupported_debt if unsupported.any?
      prompts << :payment_info_missing if reliable.any? && payments_missing
      prompts << :fx_unavailable if fx_unavailable

      Result.new(
        debt_accounts: reliable,
        unsupported_accounts: unsupported,
        total_debt_money: money(total_debt),
        monthly_payment_money: money(monthly_payments),
        estimated_months: estimated_months,
        has_payment_info: has_payment_info,
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
          [ converted_balance(account), 0.to_d ].max
        rescue Money::ConversionError
          fx_unavailable = true
          0.to_d
        end

        [ total, fx_unavailable ]
      end

      # Returns [total_in_family_currency, fx_unavailable, any_missing_payment].
      # A "missing payment" is a reliable liability that does not expose a positive
      # minimum/scheduled payment in its own currency. FX failures during payment
      # conversion count as missing too, since we cannot trust the total.
      def aggregate_payments(accounts)
        total = 0.to_d
        fx_unavailable = false
        missing = false

        accounts.each do |account|
          payment = payment_for(account)
          if payment.nil? || payment.amount.to_d <= 0
            missing = true
            next
          end

          converted = begin
            if payment.currency.iso_code == family.currency
              payment.amount
            else
              payment.exchange_to(family.currency).amount
            end
          rescue Money::ConversionError
            fx_unavailable = true
            missing = true
            0.to_d
          end

          total += converted
        end

        [ total, fx_unavailable, missing ]
      end

      def payment_for(account)
        case account.accountable_type
        when "CreditCard"
          account.accountable.minimum_payment_money
        when "Loan"
          account.accountable.monthly_payment
        end
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
