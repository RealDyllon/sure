require "test_helper"

class GoalsSupportingCalculatorsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.accounts.each { |account| account.entries.destroy_all }
    @family.accounts.update_all(status: "disabled")
    @family.update!(country: "SG", currency: "SGD")
    @profile = GoalProfile.find_or_create_for!(@user)
    @profile.update!(annual_spending_override: 48_000, emergency_fund_months: 6)
  end

  test "emergency fund uses included cash-like accounts without removing them from FIRE bridge" do
    cash = create_account(name: "Example Cash Account", balance: 18_000, accountable: Depository.new)
    @profile.set_emergency_included_account_ids!([ cash.id ], user: @user)

    result = Goals::EmergencyFundCalculator.new(user: @user, profile: @profile.reload).call
    classifier_result = Goals::AccountClassifier.new(user: @user, profile: @profile.reload).call

    assert_equal BigDecimal("24000"), result.target_money.amount
    assert_equal BigDecimal("18000"), result.available_money.amount
    assert_equal BigDecimal("0.75"), result.progress
    assert_includes classifier_result.fire_bridge_accounts, cash
  end

  test "debt payoff excludes balances that look like available credit and flags them for review" do
    reliable_loan = create_account(name: "Example Reliable Loan", balance: 12_000, accountable: Loan.new(subtype: "other"))
    available_credit_card = create_account(
      name: "Example Available Credit Card",
      balance: 15_000,
      accountable: CreditCard.new(available_credit: 15_000)
    )

    result = Goals::DebtPayoffCalculator.new(user: @user, profile: @profile).call

    assert_includes result.debt_accounts, reliable_loan
    assert_not_includes result.debt_accounts, available_credit_card
    assert_includes result.unsupported_accounts, available_credit_card
    assert_equal BigDecimal("12000"), result.total_debt_money.amount
  end

  test "savings rate calculates from recent income and expenses when history exists" do
    account = create_account(name: "Example Spending Account", balance: 5_000, accountable: Depository.new)
    create_transaction(account: account, name: "Example Salary", amount: -8_000, currency: "SGD", date: 1.month.ago)
    create_transaction(account: account, name: "Example Groceries", amount: 2_000, currency: "SGD", date: 1.month.ago)
    create_transaction(account: account, name: "Example Rent", amount: 2_000, currency: "SGD", date: 1.month.ago)

    result = Goals::SavingsRateCalculator.new(user: @user, profile: @profile).call

    assert_equal BigDecimal("8000"), result.monthly_income_money.amount
    assert_equal BigDecimal("4000"), result.monthly_expenses_money.amount
    assert_equal BigDecimal("0.5"), result.savings_rate
    assert result.target_available?
  end

  test "savings rate returns metric-only state when no target can be inferred" do
    account = create_account(name: "Example Spending Account", balance: 5_000, accountable: Depository.new)
    create_transaction(account: account, name: "Example Salary", amount: -8_000, currency: "SGD", date: 1.month.ago)
    create_transaction(account: account, name: "Example Groceries", amount: 2_000, currency: "SGD", date: 1.month.ago)
    @profile.update!(annual_spending_override: nil, savings_rate_target: nil)

    result = Goals::SavingsRateCalculator.new(user: @user, profile: @profile.reload).call

    assert_equal BigDecimal("0.75"), result.savings_rate
    assert_not result.target_available?
    assert_empty result.review_prompts
  end

  test "savings rate reports insufficient history when no recent income is available" do
    @profile.update!(annual_spending_override: nil, savings_rate_target: nil)

    result = Goals::SavingsRateCalculator.new(user: @user, profile: @profile.reload).call

    assert_nil result.savings_rate
    assert_not result.target_available?
    assert_includes result.review_prompts, :insufficient_history
  end

  test "custom goal calculator uses valid funding accounts and target currency" do
    cash = create_account(name: "Example Custom Goal Cash", balance: 4_000, accountable: Depository.new)
    brokerage = create_account(name: "Example Custom Goal Brokerage", balance: 6_000, accountable: Investment.new(subtype: "brokerage"))
    goal = FinancialGoal.create!(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example Custom Goal",
      target_amount: 20_000,
      target_currency: "SGD"
    )
    goal.set_funding_account_ids!(user: @user, account_ids: [ cash.id, brokerage.id ])

    result = Goals::CustomGoalCalculator.new(goal: goal, user: @user).call

    assert_equal BigDecimal("10000"), result.available_money.amount
    assert_equal BigDecimal("20000"), result.target_money.amount
    assert_equal BigDecimal("0.5"), result.progress
  end

  test "custom goal calculator flags unavailable FX without blocking the goal" do
    usd_account = create_account(name: "Example USD Account", balance: 4_000, accountable: Depository.new, currency: "USD")
    goal = FinancialGoal.create!(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example FX Goal",
      target_amount: 20_000,
      target_currency: "SGD"
    )
    goal.set_funding_account_ids!(user: @user, account_ids: [ usd_account.id ])

    result = Goals::CustomGoalCalculator.new(goal: goal, user: @user).call

    assert result.fx_unavailable?
    assert_includes result.review_prompts, :fx_unavailable
  end

  private
    def create_account(name:, balance:, accountable:, currency: @family.currency)
      @family.accounts.create!(
        owner: @user,
        name: name,
        balance: balance,
        cash_balance: balance,
        currency: currency,
        accountable: accountable
      )
    end
end
