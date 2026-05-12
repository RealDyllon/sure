module Goals
  class AssumptionsController < ApplicationController
    def show
      @profile = GoalProfile.find_or_create_for!(Current.user)
      load_accounts
    end

    def update
      @profile = GoalProfile.find_or_create_for!(Current.user)
      if @profile.update(goal_profile_params)
        redirect_to goals_path
      else
        load_accounts

        render :show, status: :unprocessable_entity
      end
    end

    private
      def load_accounts
        @accounts = Current.user.finance_accounts.visible.alphabetically.includes(:accountable)
      end

      def goal_profile_params
        params.require(:goal_profile).permit(
          :planning_region,
          :current_age,
          :birth_year,
          :annual_spending_override,
          :withdrawal_rate,
          :expected_return,
          :inflation_rate,
          :savings_rate_target,
          :cpf_access_age,
          :cpf_life_age,
          :srs_access_age,
          :emergency_fund_months
        )
      end
  end
end
