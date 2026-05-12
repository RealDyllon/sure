require "test_helper"

class GoalsAssociationTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = users(:empty)
  end

  test "family deletion destroys goal profiles financial goals and funding mappings" do
    profile = GoalProfile.find_or_create_for!(@user)
    goal = create_goal(@user)
    account = create_account(@user)
    goal.set_funding_account_ids!(user: @user, account_ids: [ account.id ])

    assert_difference -> { GoalProfile.where(id: profile.id).count }, -1 do
      assert_difference -> { FinancialGoal.where(id: goal.id).count }, -1 do
        assert_difference -> { FinancialGoalFundingAccount.where(financial_goal_id: goal.id).count }, -1 do
          @family.destroy!
        end
      end
    end
  end

  test "user deletion destroys their goal profile goals and funding mappings" do
    member = @family.users.create!(
      first_name: "Example",
      last_name: "Member",
      email: "example-goals-member@example.com",
      password: user_password_test,
      role: "member",
      onboarded_at: Time.current,
      ui_layout: "dashboard"
    )
    profile = GoalProfile.find_or_create_for!(member)
    goal = create_goal(member)
    account = create_account(member)
    goal.set_funding_account_ids!(user: member, account_ids: [ account.id ])

    assert_difference -> { GoalProfile.where(id: profile.id).count }, -1 do
      assert_difference -> { FinancialGoal.where(id: goal.id).count }, -1 do
        assert_difference -> { FinancialGoalFundingAccount.where(financial_goal_id: goal.id).count }, -1 do
          member.destroy!
        end
      end
    end
  end

  private
    def create_goal(user)
      FinancialGoal.create!(
        family: user.family,
        user: user,
        goal_type: "custom",
        name: "Example Custom Goal",
        target_amount: 10_000,
        target_currency: user.family.currency
      )
    end

    def create_account(user)
      user.family.accounts.create!(
        owner: user,
        name: "Example Goal Funding Account",
        balance: 5_000,
        currency: user.family.currency,
        accountable: Depository.new
      )
    end
end
