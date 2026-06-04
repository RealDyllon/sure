require "test_helper"

class FinancialGoalTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
  end

  test "custom goal validates name target amount and target currency" do
    goal = FinancialGoal.new(family: @family, user: @user, goal_type: "custom")

    assert_not goal.valid?
    assert_includes goal.errors[:name], "can't be blank"
    assert_includes goal.errors[:target_amount], "can't be blank"
    assert_includes goal.errors[:target_currency], "can't be blank"
  end

  test "custom goal exposes target amount as money in target currency" do
    goal = FinancialGoal.create!(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example Education Goal",
      target_amount: 25_000,
      target_currency: "SGD",
      target_date: 2.years.from_now.to_date
    )

    assert_equal BigDecimal("25000"), goal.target_amount_money.amount
    assert_equal "SGD", goal.target_amount_money.currency.iso_code
  end

  test "custom goal validates and normalizes target currency" do
    goal = FinancialGoal.new(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example Invalid Currency Goal",
      target_amount: 10_000,
      target_currency: "xyz"
    )

    assert_not goal.valid?
    assert_includes goal.errors[:target_currency], "is not supported"
    assert_equal "XYZ", goal.target_currency

    goal.target_currency = "sgd"

    assert goal.valid?
    assert_equal "SGD", goal.target_currency
  end

  test "goal type is constrained to supported persisted goal rows" do
    goal = FinancialGoal.new(
      family: @family,
      user: @user,
      goal_type: "fire"
    )

    assert_not goal.valid?
    assert_includes goal.errors[:goal_type], "is not included in the list"
  end

  test "active goals are ordered by position then created date" do
    second = FinancialGoal.create!(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example Second Goal",
      target_amount: 20_000,
      target_currency: "USD",
      position: 2
    )
    first = FinancialGoal.create!(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example First Goal",
      target_amount: 10_000,
      target_currency: "USD",
      position: 1
    )

    assert_equal [ first, second ], FinancialGoal.active.ordered.where(id: [ first.id, second.id ]).to_a
  end

  test "active goals with the same position are ordered by created date" do
    older = FinancialGoal.create!(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example Older Goal",
      target_amount: 10_000,
      target_currency: "USD",
      position: 1
    )

    travel 1.second do
      newer = FinancialGoal.create!(
        family: @family,
        user: @user,
        goal_type: "custom",
        name: "Example Newer Goal",
        target_amount: 20_000,
        target_currency: "USD",
        position: 1
      )

      assert_equal [ older, newer ], FinancialGoal.active.ordered.where(id: [ older.id, newer.id ]).to_a
    end
  end

  test "archive changes status without destroying the goal" do
    goal = FinancialGoal.create!(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example Archived Goal",
      target_amount: 10_000,
      target_currency: "USD"
    )

    assert_no_difference "FinancialGoal.count" do
      goal.archive!
    end

    assert goal.reload.archived?
    assert_not_includes FinancialGoal.active, goal
  end

  test "funding accounts are limited to the user's finance-included accounts" do
    member = users(:family_member)
    shared_account = accounts(:depository)
    unshared_account = create_account(name: "Example Unshared Account", balance: 8_000)
    other_family_account = families(:empty).accounts.create!(
      owner: users(:empty),
      name: "Example Other Family Account",
      balance: 3_000,
      currency: "USD",
      accountable: Depository.new
    )
    goal = FinancialGoal.create!(
      family: @family,
      user: member,
      goal_type: "custom",
      name: "Example Family Trip",
      target_amount: 12_000,
      target_currency: "USD"
    )

    goal.set_funding_account_ids!(
      user: member,
      account_ids: [ shared_account.id, unshared_account.id, other_family_account.id, "missing-account" ]
    )

    assert_equal [ shared_account.id ], goal.reload.funding_account_ids_for(member)
  end

  test "funding accounts are filtered when finance inclusion changes after save" do
    member = users(:family_member)
    shared_account = accounts(:depository)
    goal = FinancialGoal.create!(
      family: @family,
      user: member,
      goal_type: "custom",
      name: "Example Stale Account Goal",
      target_amount: 12_000,
      target_currency: "USD"
    )
    goal.set_funding_account_ids!(user: member, account_ids: [ shared_account.id ])

    account_shares(:depository_shared_with_member).update!(include_in_finances: false)

    assert_equal [], goal.reload.funding_account_ids_for(member)
  end

  private
    def create_account(name:, balance:, accountable: Depository.new, currency: @family.currency)
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
