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

    private
      def scenario_params
        params.fetch(:scenario, {}).permit(:annual_spending, :withdrawal_rate, :annual_contribution)
      end
  end
end
