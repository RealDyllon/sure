module Goals
  class DebtPayoffCalculator
    Result = Data.define(
      :debt_accounts,
      :debt_account_reasons,
      :unsupported_accounts,
      :total_debt_money,
      :monthly_payment_money,
      :estimated_months,
      :has_payment_info,
      :review_prompts
    ) do
      def has_payment_info? = has_payment_info

      # Per-account reason. The view can render a tailored message per card
      # (e.g., "this card has no minimum payment" vs. "this card is in an
      # unconvertible currency") rather than collapsing all reasons into a
      # single card-level prompt that misleads when one account has a payment
      # and another doesn't.
      def reason_for(account)
        debt_account_reasons[account.id]
      end
    end

    def initialize(user:, profile:)
      @user = user
      @profile = profile
      @family = user.family
    end

    def call
      reliable, unsupported = liability_accounts.partition { |account| reliable_debt_account?(account) }
      total_debt, debt_fx_unavailable = sum_balances(reliable)
      reasons, monthly_payments, fx_unavailable, payments_missing = aggregate_payments(reliable)
      has_payment_info = !fx_unavailable && !payments_missing && reliable.any?

      # When we can't compute a complete payment total, expose a zero rather than a
      # partial sum: callers branch on has_payment_info / review_prompts, so the
      # money value is only ever user-facing when we trust it.
      monthly_payment_total = has_payment_info ? monthly_payments : 0.to_d

      estimated_months = if has_payment_info && monthly_payments.positive?
        (total_debt / monthly_payments).ceil
      end

      prompts = []
      prompts << :unsupported_debt if unsupported.any?
      prompts << :payment_info_missing if reasons.value?(:payment_missing)
      prompts << :fx_unavailable if fx_unavailable

      Result.new(
        debt_accounts: reliable,
        debt_account_reasons: reasons,
        unsupported_accounts: unsupported,
        total_debt_money: money(total_debt),
        monthly_payment_money: money(monthly_payment_total),
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

      # Returns a 4-tuple:
      #   [reasons, total_payments, fx_unavailable, any_payment_missing].
      # `reasons` is a { account_id => :ok | :payment_missing | :fx_unavailable }
      # hash keyed by account id so the view can render per-account messages.
      # A payment that exists but can't be FX-converted is tagged :fx_unavailable
      # (not :payment_missing): the user already supplied the payment; FX is the
      # blocker.
      def aggregate_payments(accounts)
        reasons = {}
        total = 0.to_d
        fx_unavailable = false
        missing = false

        accounts.each do |account|
          payment = payment_for(account)
          if payment.nil? || payment.amount.to_d <= 0
            reasons[account.id] = :payment_missing
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
            reasons[account.id] = :fx_unavailable
            0.to_d
          end

          reasons[account.id] ||= :ok
          total += converted
        end

        [ reasons, total, fx_unavailable, missing ]
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
