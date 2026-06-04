module Goals
  class AssumptionsController < ApplicationController
    def show
      @profile = GoalProfile.find_or_create_for!(Current.user)
      load_accounts
      load_emergency_account_ids
    end

    def update
      @profile = GoalProfile.find_or_create_for!(Current.user)
      if @profile.update(goal_profile_params)
        redirect_to goals_path
      else
        load_accounts
        load_emergency_account_ids

        render :show, status: :unprocessable_entity
      end
    end

    private
      def load_accounts
        @accounts = Current.user.finance_accounts.visible.alphabetically.includes(:accountable)
      end

      def load_emergency_account_ids
        @emergency_account_ids = if @profile.emergency_account_ids_overridden?
          @profile.emergency_account_ids
        else
          Goals::AccountClassifier.new(user: Current.user, profile: @profile).call.emergency_accounts.map(&:id)
        end
      end

      def goal_profile_params
        params.require(:goal_profile).permit(
          :planning_region,
          :current_age,
          :birth_year,
          :annual_spending_override,
          :annual_contribution,
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
