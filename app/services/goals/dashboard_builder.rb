module Goals
  class DashboardBuilder
    Result = Data.define(:profile, :fire, :emergency_fund, :debt_payoff, :savings_rate, :custom_goals)

    def initialize(user:)
      @user = user
      @profile = GoalProfile.find_or_create_for!(user)
    end

    def call
      Result.new(
        profile: profile,
        fire: Goals::FireCalculator.new(user: user, profile: profile).call,
        emergency_fund: Goals::EmergencyFundCalculator.new(user: user, profile: profile).call,
        debt_payoff: Goals::DebtPayoffCalculator.new(user: user, profile: profile).call,
        savings_rate: Goals::SavingsRateCalculator.new(user: user, profile: profile).call,
        custom_goals: user.financial_goals.active.ordered.map { |goal| Goals::CustomGoalCalculator.new(goal: goal, user: user).call }
      )
    end

    private
      attr_reader :user, :profile
  end
end
