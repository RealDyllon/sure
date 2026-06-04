class GoalsController < ApplicationController
  def index
    @dashboard = Goals::DashboardBuilder.new(user: Current.user).call
    @profile = @dashboard.profile
    @fire = @dashboard.fire
    @accounts = Current.user.finance_accounts.visible.assets.alphabetically
    @financial_goal = Current.user.financial_goals.build(
      family: Current.family,
      goal_type: "custom",
      target_currency: Current.family.currency
    )
  end
end
