class FinancialGoalsController < ApplicationController
  def create
    goal = Current.user.financial_goals.build(financial_goal_params.except(:funding_account_ids))
    goal.family = Current.family
    if goal.save
      goal.set_funding_account_ids!(user: Current.user, account_ids: funding_account_ids)

      redirect_to goals_path
    else
      prepare_goals_index(financial_goal: goal)
      render "goals/index", status: :unprocessable_entity
    end
  end

  def update
    goal = Current.user.financial_goals.find(params[:id])
    if goal.update(financial_goal_params.except(:funding_account_ids))
      goal.set_funding_account_ids!(user: Current.user, account_ids: funding_account_ids)

      redirect_to goals_path
    else
      prepare_goals_index(financial_goal: goal)
      render "goals/index", status: :unprocessable_entity
    end
  end

  def archive
    goal = Current.user.financial_goals.find(params[:id])
    goal.archive!

    redirect_to goals_path
  end

  private
    def financial_goal_params
      params.require(:financial_goal).permit(
        :goal_type,
        :name,
        :target_amount,
        :target_currency,
        :target_date,
        :position,
        funding_account_ids: []
      )
    end

    def funding_account_ids
      financial_goal_params.fetch(:funding_account_ids, [])
    end

    def prepare_goals_index(financial_goal:)
      @dashboard = Goals::DashboardBuilder.new(user: Current.user).call
      @profile = @dashboard.profile
      @fire = @dashboard.fire
      @accounts = Current.user.finance_accounts.visible.assets.alphabetically
      @financial_goal = financial_goal
    end
end
