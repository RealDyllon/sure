module Goals
  class SavingsRateCalculator
    Result = Data.define(
      :monthly_income_money,
      :monthly_expenses_money,
      :savings_rate,
      :target_available,
      :review_prompts
    ) do
      def target_available? = target_available
    end

    def initialize(user:, profile:)
      @user = user
      @profile = profile
      @family = user.family
    end

    def call
      income, expenses, months = recent_income_expenses
      monthly_income = months.positive? ? income / months : 0.to_d
      monthly_expenses = months.positive? ? expenses / months : 0.to_d
      rate = monthly_income.positive? ? (monthly_income - monthly_expenses) / monthly_income : nil
      prompts = rate.nil? ? [ :insufficient_history ] : []

      Result.new(
        monthly_income_money: money(monthly_income),
        monthly_expenses_money: money(monthly_expenses),
        savings_rate: rate,
        target_available: target_available?,
        review_prompts: prompts
      )
    end

    private
      attr_reader :user, :profile, :family

      def recent_income_expenses
        account_ids = user.finance_accounts.visible.pluck(:id)
        return [ 0.to_d, 0.to_d, 0 ] if account_ids.empty?

        entries = Entry.where(account_id: account_ids, entryable_type: "Transaction")
          .where(excluded: false)
          .where("date >= ?", 3.months.ago.to_date)

        income = 0.to_d
        expenses = 0.to_d
        active_months = Set.new

        entries.find_each do |entry|
          active_months << entry.date.beginning_of_month if entry.date
          amount = converted_entry_amount(entry)
          if amount.negative?
            income += amount.abs
          else
            expenses += amount
          end
        end

        [ income, expenses, active_months.count ]
      end

      def converted_entry_amount(entry)
        return entry.amount.to_d if entry.currency == family.currency

        Money.new(entry.amount, entry.currency).exchange_to(family.currency, date: entry.date).amount
      rescue Money::ConversionError
        0.to_d
      end

      def target_available?
        profile.savings_rate_target.present? || profile.annual_spending_override.present?
      end

      def money(amount)
        Money.new(amount, family.currency)
      end
  end
end
