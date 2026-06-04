module Goals
  class FireController < ApplicationController
    def show
      @profile = GoalProfile.find_or_create_for!(Current.user)
      @fire = ::Goals::FireCalculator.new(user: Current.user, profile: @profile).call
    end

    def preview
      @profile = GoalProfile.find_or_create_for!(Current.user)
      @fire = ::Goals::FireCalculator.new(
        user: Current.user,
        profile: @profile,
        scenario: scenario_params.to_h
      ).call

      render :show
    end

    def save_scenario
      @profile = GoalProfile.find_or_create_for!(Current.user)
      @profile.assign_attributes(scenario_goal_profile_params)

      if @profile.save
        redirect_to goals_fire_path
      else
        @fire = ::Goals::FireCalculator.new(
          user: Current.user,
          profile: @profile,
          scenario: scenario_params.to_h
        ).call

        render :show, status: :unprocessable_entity
      end
    end

    private
      def scenario_params
        params.fetch(:scenario, {}).permit(:annual_spending, :withdrawal_rate, :annual_contribution)
      end

      def scenario_goal_profile_params
        permitted = scenario_params
        {
          annual_spending_override: permitted[:annual_spending],
          withdrawal_rate: permitted[:withdrawal_rate],
          annual_contribution: permitted[:annual_contribution]
        }.compact_blank
      end
  end
end
