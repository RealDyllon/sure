module Planning
  class FireController < ApplicationController
    before_action :require_preview
    before_action :set_profile

    def show
      calculate
    end

    def update
      @profile.assign_attributes(profile_params)
      @profile.account_role_overrides = params.fetch(:fire_roles, {}).permit(*@accounts.map(&:id)).to_h if params.key?(:fire_roles)
      if @profile.valid?
        @profile.account_role_overrides = @profile.fire_role_overrides
        if params[:commit_mode] == "preview"
          calculate
          render :show
        else
          @profile.save!
          redirect_to plan_fire_path, notice: t("fire.saved")
        end
      else
        render :show, status: :unprocessable_entity
      end
    end

    private
      def require_preview
        redirect_to budgets_path unless preview_features_enabled?
      end

      def set_profile
        @profile = FireProfile.for_user!(Current.user)
        @accounts = Current.user.finance_accounts.visible.includes(:accountable)
      end

      def calculate
        @fire = FireCalculator.new(user: Current.user, profile: @profile).call
      end

      def profile_params
        params.require(:fire_profile).permit(:planning_region, :current_age, :annual_spending_override, :annual_contribution, :withdrawal_rate, :expected_return, :inflation_rate, :cpf_access_age, :cpf_life_age, :srs_access_age)
      end
  end
end
