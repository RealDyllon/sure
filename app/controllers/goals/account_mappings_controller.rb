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
  end
end
