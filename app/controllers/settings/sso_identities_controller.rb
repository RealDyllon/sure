# frozen_string_literal: true

class Settings::SsoIdentitiesController < ApplicationController
  layout "settings"

  def show
    @oidc_identities = Current.user.oidc_identities.order(:provider)
    @breadcrumbs = [
      [ t("settings.nav.home"), root_path ],
      [ t(".page_title"), nil ]
    ]
  end

  def destroy
    @identity = Current.user.oidc_identities.find(params[:id])

    # Prevent unlinking last identity if user has no password
    if Current.user.oidc_identities.count == 1 && Current.user.password_digest.blank?
      redirect_to settings_sso_identities_path, alert: t(".cannot_unlink_last")
      return
    end

    provider_name = @identity.provider
    @identity.destroy!

    # Log account unlinking
    SsoAuditLog.log_unlink!(
      user: Current.user,
      provider: provider_name,
      request: request
    )

    redirect_to settings_sso_identities_path, notice: t(".success", provider: provider_name)
  end
end
