class FinancialGoalsController < ApplicationController
  def create
    goal = Current.user.financial_goals.build(financial_goal_params.except(:funding_account_ids))
    goal.family = Current.family
    goal.save!
    goal.set_funding_account_ids!(user: Current.user, account_ids: funding_account_ids)

    redirect_to goals_path
  end

  def update
    goal = Current.user.financial_goals.find(params[:id])
    goal.update!(financial_goal_params.except(:funding_account_ids))
    goal.set_funding_account_ids!(user: Current.user, account_ids: funding_account_ids)

    redirect_to goals_path
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
end
