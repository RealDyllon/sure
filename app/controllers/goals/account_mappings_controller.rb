module Goals
  class AccountMappingsController < ApplicationController
    def update
      profile = GoalProfile.find_or_create_for!(Current.user)
      profile.update_account_role_overrides!(
        user: Current.user,
        fire_roles: params.fetch(:fire_roles, {}),
        emergency_account_ids: params.fetch(:emergency_account_ids, [])
      )

      redirect_to goals_path
    end

    def skip_prompt
      profile = GoalProfile.find_or_create_for!(Current.user)
      prompt = params[:prompt].to_s
      return head :bad_request unless prompt == "srs"

      profile.skip_prompt!(prompt)

      redirect_back fallback_location: goals_path
    end
  end
end
