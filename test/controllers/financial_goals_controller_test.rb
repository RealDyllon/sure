require "test_helper"

class FinancialGoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "creates a custom financial goal scoped to the current family and user" do
    account = accounts(:depository)

    assert_difference "FinancialGoal.count", 1 do
      post financial_goals_path, params: {
        financial_goal: {
          goal_type: "custom",
          name: "Example Trip Goal",
          target_amount: 15_000,
          target_currency: "USD",
          target_date: 1.year.from_now.to_date,
          funding_account_ids: [ account.id ]
        }
      }
    end

    goal = FinancialGoal.order(:created_at).last
    assert_redirected_to goals_path
    assert_equal @family, goal.family
    assert_equal @user, goal.user
    assert_equal [ account.id ], goal.funding_account_ids_for(@user)
  end

  test "create renders validation errors for invalid custom goal input" do
    assert_no_difference "FinancialGoal.count" do
      post financial_goals_path, params: {
        financial_goal: {
          goal_type: "custom",
          name: "Example Invalid Goal",
          target_amount: "",
          target_currency: "XYZ"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "h1", text: "Goals"
    assert_select ".text-destructive", text: /Target amount/
    assert_select ".text-destructive", text: /Target currency/
  end

  test "updates a custom goal and ignores stale funding account IDs" do
    goal = FinancialGoal.create!(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example Original Goal",
      target_amount: 10_000,
      target_currency: "USD"
    )
    valid_account = accounts(:depository)

    stale_account_id = SecureRandom.uuid
    other_family_account = families(:empty).accounts.create!(
      owner: users(:empty),
      name: "Example Other Family Funding Account",
      balance: 10_000,
      currency: "USD",
      accountable: Depository.new
    )

    patch financial_goal_path(goal), params: {
      financial_goal: {
        name: "Example Updated Goal",
        target_amount: 20_000,
        target_currency: "SGD",
        funding_account_ids: [ valid_account.id, stale_account_id, other_family_account.id ]
      }
    }

    assert_redirected_to goals_path
    assert_equal "Example Updated Goal", goal.reload.name
    assert_equal BigDecimal("20000"), goal.target_amount
    assert_equal "SGD", goal.target_currency
    assert_equal [ valid_account.id ], goal.funding_account_ids_for(@user)
  end

  test "archives a custom goal instead of destroying it" do
    goal = FinancialGoal.create!(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example Archive Goal",
      target_amount: 10_000,
      target_currency: "USD"
    )

    assert_no_difference "FinancialGoal.count" do
      patch archive_financial_goal_path(goal)
    end

    assert_redirected_to goals_path
    assert goal.reload.archived?
  end

  test "does not allow updating another family's goal" do
    other_goal = FinancialGoal.create!(
      family: families(:empty),
      user: users(:empty),
      goal_type: "custom",
      name: "Example Other Family Goal",
      target_amount: 10_000,
      target_currency: "USD"
    )

    patch financial_goal_path(other_goal), params: {
      financial_goal: { name: "Example Invalid Update" }
    }

    assert_response :not_found
    assert_equal "Example Other Family Goal", other_goal.reload.name
  end
end
