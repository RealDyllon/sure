module Goals
  class FireController < ApplicationController
    def show
      @profile = GoalProfile.find_or_create_for!(Current.user)
      @scenario = {}
      @fire = ::Goals::FireCalculator.new(user: Current.user, profile: @profile).call
    end

    def preview
      @profile = GoalProfile.find_or_create_for!(Current.user)
      @scenario = scenario_params.to_h.symbolize_keys
      @fire = ::Goals::FireCalculator.new(
        user: Current.user,
        profile: @profile,
        scenario: @scenario
      ).call

      render :show
    end

    def save_scenario
      @profile = GoalProfile.find_or_create_for!(Current.user)
      update_attrs = scenario_goal_profile_params
      @profile.assign_attributes(update_attrs) if update_attrs.any?

      if @profile.save
        redirect_to goals_fire_path
      else
        @scenario = scenario_params.to_h.symbolize_keys
        @fire = ::Goals::FireCalculator.new(
          user: Current.user,
          profile: @profile,
          scenario: @scenario
        ).call

        render :show, status: :unprocessable_entity
      end
    end

    private
      def scenario_params
        params.fetch(:scenario, {}).permit(:annual_spending, :withdrawal_rate, :annual_contribution)
      end

      def scenario_goal_profile_params
        raw = params.fetch(:scenario, {}).permit(:annual_spending, :withdrawal_rate, :annual_contribution)
        update = {}
        # Only include keys the form actually submitted, so absent fields don't
        # accidentally clear existing values. Blank values are intentional clears:
        #   annual_spending:  "" -> nil  (revert to inferred spending)
        #   annual_contribution: "" -> 0   (the column default)
        #   withdrawal_rate:  "" -> ""   (passed through; numericality validator
        #                                 surfaces a 422, matching the "no blank
        #                                 withdrawal rate" spec scenario)
        if raw.key?(:annual_spending)
          update[:annual_spending_override] = raw[:annual_spending].presence
        end
        if raw.key?(:annual_contribution)
          update[:annual_contribution] = raw[:annual_contribution].presence || 0
        end
        if raw.key?(:withdrawal_rate)
          update[:withdrawal_rate] = raw[:withdrawal_rate]
        end
        update
      end
  end
end
