class WiseItemsController < ApplicationController
  before_action :set_wise_item, only: %i[show edit update destroy sync setup_accounts complete_account_setup reauth]
  before_action :require_admin!, only: %i[
    new create oauth_start oauth_callback select_existing_account link_existing_account
    edit update destroy sync setup_accounts complete_account_setup reauth reauth_callback
  ]

  def index
    @wise_items = Current.family.wise_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def new
    @wise_item = Current.family.wise_items.build(name: "Wise Connection")
  end

  def create
    @wise_item = Current.family.wise_items.build(wise_item_params)
    @wise_item.name ||= t("wise_items.create.default_name")
    @wise_item.auth_mode = "personal_token"

    if @wise_item.save
      @wise_item.sync_later
      respond_to_panel_success
    else
      respond_to_panel_error(@wise_item.errors.full_messages.join(", "))
    end
  end

  def edit
  end

  def update
    if @wise_item.update(wise_item_params)
      respond_to_panel_success
    else
      respond_to_panel_error(@wise_item.errors.full_messages.join(", "))
    end
  end

  def oauth_start
    unless Provider::Wise.oauth_configured?
      redirect_to settings_providers_path, alert: t("wise_items.oauth.not_configured")
      return
    end

    state = SecureRandom.hex(24)
    session[:wise_oauth_state] = state
    redirect_uri = Provider::Wise.oauth_redirect_uri.presence || oauth_callback_wise_items_url

    redirect_to Provider::Wise.oauth_authorize_url(redirect_uri: redirect_uri, state: state), allow_other_host: true
  end

  def oauth_callback
    if params[:error].present?
      redirect_to settings_providers_path, alert: "#{t('wise_items.oauth.failure_prefix')} #{params[:error_description].presence || params[:error]}"
      return
    end

    expected_state = session.delete(:wise_oauth_state)
    unless expected_state.present? && params[:state].present? && ActiveSupport::SecurityUtils.secure_compare(expected_state.to_s, params[:state].to_s)
      redirect_to settings_providers_path, alert: t("wise_items.oauth.state_mismatch")
      return
    end

    redirect_uri = Provider::Wise.oauth_redirect_uri.presence || oauth_callback_wise_items_url
    oauth_base_url = Provider::Wise.oauth_base_url
    oauth_auth_url = Provider::Wise.oauth_auth_url
    provider = Provider::Wise.new(
      access_token: nil,
      base_url: oauth_base_url,
      auth_url: oauth_auth_url,
      client_id: Provider::Wise.oauth_client_id,
      client_secret: Provider::Wise.oauth_client_secret
    )
    token_payload = provider.exchange_code_for_token(code: params.require(:code), redirect_uri: redirect_uri).with_indifferent_access

    wise_item = Current.family.wise_items.create!(
      name: t("wise_items.create.default_name"),
      auth_mode: "oauth",
      # Wise's standard OAuth callback only returns `code` + `state`. The
      # `profileId` fallback is for self-hosters running a custom proxy that
      # pre-selects a profile before the redirect.
      profile_id: params[:profileId].presence || params[:profile_id].presence,
      base_url: oauth_base_url,
      auth_url: oauth_auth_url,
      access_token: token_payload[:access_token],
      refresh_token: token_payload[:refresh_token],
      token_expires_at: token_payload[:expires_in].present? ? Time.current + token_payload[:expires_in].to_i.seconds : nil
    )
    wise_item.sync_later

    redirect_to accounts_path, notice: t("wise_items.create.success")
  rescue Provider::Wise::WiseError => e
    redirect_to settings_providers_path, alert: "#{t('wise_items.oauth.failure_prefix')} #{e.message}"
  end

  def destroy
    @wise_item.unlink_all!(dry_run: false)
    @wise_item.destroy_later
    redirect_to accounts_path, notice: t("wise_items.destroy.success")
  end

  def sync
    @wise_item.sync_later unless @wise_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def setup_accounts
    fetch_wise_balances_if_needed
    @wise_balances = @wise_item.wise_balances.requires_setup.order(:currency)
    @existing_accounts = Current.family.accounts.visible_manual.where(accountable_type: "Depository").alphabetically
    @default_actions, @default_existing_account_ids = compute_default_setup_actions(@wise_balances, @existing_accounts)
    @setup_errors = {}
  end

  def complete_account_setup
    balance_actions = params[:balance_actions] || {}
    existing_account_ids = params[:existing_account_ids] || {}

    # Form params arrive with string keys, but the view looks up
    # selections and errors by integer `wise_balance.id`. Normalize
    # both maps so the 422 re-render can find the rows the user just
    # submitted, and the per-row error renders against the right
    # balance.
    balance_actions = balance_actions.to_unsafe_h.stringify_keys if balance_actions.respond_to?(:to_unsafe_h)
    existing_account_ids = existing_account_ids.to_unsafe_h.stringify_keys if existing_account_ids.respond_to?(:to_unsafe_h)
    setup_errors = {}
    claimed_account_ids = Set.new
    resolved = []

    balance_actions.each do |wise_balance_id_str, action|
      wise_balance = @wise_item.wise_balances.find_by(id: wise_balance_id_str)
      next unless wise_balance
      next if wise_balance.account_provider.present?

      case action
      when "create"
        resolved << { balance: wise_balance, action: "create" }
      when "link"
        target_id = existing_account_ids[wise_balance_id_str]
        account = Current.family.accounts.visible_manual.where(accountable_type: "Depository").find_by(id: target_id)
        if account.nil?
          setup_errors[wise_balance_id_str] = t("wise_items.complete_account_setup.errors.missing_target")
        elsif provider_linked_account?(account)
          setup_errors[wise_balance_id_str] = t("wise_items.complete_account_setup.errors.already_linked")
        elsif claimed_account_ids.include?(account.id)
          # Two balance rows chose the same existing account in this
          # submit. `provider_linked_account?` only sees what's in the
          # DB, so we have to track in-request claims ourselves to
          # avoid hitting a uniqueness constraint inside the
          # transaction and surfacing a 500.
          setup_errors[wise_balance_id_str] = t("wise_items.complete_account_setup.errors.duplicate_target")
        else
          claimed_account_ids << account.id
          resolved << { balance: wise_balance, action: "link", account: account }
        end
      when "skip"
        resolved << { balance: wise_balance, action: "skip" }
      else
        # Unknown action values fall back to skip rather than silently
        # creating a row with no clear intent.
        resolved << { balance: wise_balance, action: "skip" }
      end
    end

    if setup_errors.any?
      fetch_wise_balances_if_needed
      @wise_balances = @wise_item.wise_balances.requires_setup.order(:currency)
      @existing_accounts = Current.family.accounts.visible_manual.where(accountable_type: "Depository").alphabetically
      @default_actions, @default_existing_account_ids = compute_default_setup_actions(@wise_balances, @existing_accounts)
      @setup_errors = setup_errors
      @action_selections = balance_actions
      @existing_account_selections = existing_account_ids
      render :setup_accounts, status: :unprocessable_entity
      return
    end

    created_or_linked = 0
    skipped = 0

    # Second pass: only after we know all rows are valid do we enter the
    # transaction. Any DB error mid-transaction rolls the whole batch back.
    ActiveRecord::Base.transaction do
      resolved.each do |row|
        case row[:action]
        when "create"
          account = Account.create_and_sync(
            {
              family: Current.family,
              name: row[:balance].name.presence || "Wise #{row[:balance].currency}",
              balance: row[:balance].current_balance || 0,
              currency: row[:balance].currency,
              accountable_type: "Depository",
              accountable_attributes: {}
            },
            skip_initial_sync: true
          )
          AccountProvider.create!(account: account, provider: row[:balance])
          row[:balance].clear_skipped!
          created_or_linked += 1
        when "link"
          AccountProvider.create!(account: row[:account], provider: row[:balance])
          row[:balance].clear_skipped!
          created_or_linked += 1
        when "skip"
          row[:balance].mark_skipped!
          skipped += 1
        end
      end
    end

    @wise_item.update!(pending_account_setup: @wise_item.unlinked_accounts_count.positive?)
    @wise_item.sync_later if created_or_linked.positive?

    flash[:notice] = if created_or_linked.positive?
      t("wise_items.complete_account_setup.success", count: created_or_linked)
    elsif skipped.positive?
      t("wise_items.complete_account_setup.skipped")
    else
      t("wise_items.complete_account_setup.no_changes")
    end

    redirect_to accounts_path, status: :see_other
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    if provider_linked_account?(@account)
      redirect_to accounts_path, alert: t("wise_items.link_existing_account.already_linked")
      return
    end

    @available_wise_balances = Current.family.wise_items.includes(:wise_balances).flat_map(&:wise_balances)
      .select { |balance| balance.account_provider.nil? && !balance.skipped? }
      .sort_by { |balance| [ balance.currency.to_s, balance.name.to_s ] }
    @return_to = safe_return_to_path

    render layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    wise_balance = WiseBalance.find(params[:wise_balance_id])
    return redirect_to accounts_path, alert: t("wise_items.link_existing_account.already_linked") if provider_linked_account?(account)
    return redirect_to accounts_path, alert: t("wise_items.link_existing_account.wrong_family") unless wise_balance.wise_item.family_id == Current.family.id
    return redirect_to accounts_path, alert: t("wise_items.link_existing_account.only_depository") unless account.accountable_type == "Depository"
    return redirect_to accounts_path, alert: t("wise_items.link_existing_account.balance_already_linked") if wise_balance.account_provider.present?

    AccountProvider.create!(account: account, provider: wise_balance)
    wise_balance.clear_skipped!
    wise_balance.wise_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t("wise_items.link_existing_account.success", account_name: account.name)
  end

  def reauth
    unless Provider::Wise.oauth_configured?
      redirect_to settings_providers_path, alert: t("wise_items.reauth.not_configured")
      return
    end

    state = SecureRandom.hex(24)
    session[:wise_oauth_state] = state
    session[:wise_oauth_reauth_id] = @wise_item.id
    # Reauth always uses the dedicated reauth callback URL even if a global
    # WISE_REDIRECT_URI is configured. The reauth flow needs to know which
    # WiseItem to update on return, and that bookkeeping only lives in this
    # controller's session.
    redirect_uri = reauth_callback_wise_items_url
    # Use the item's stored OAuth hosts (sandbox, custom proxy, etc.)
    # rather than the current global defaults, so a reauth keeps working
    # when the item was originally connected to a different environment
    # than the one configured globally today.
    redirect_to Provider::Wise.oauth_authorize_url(
      redirect_uri: redirect_uri,
      state: state,
      auth_url: @wise_item.effective_auth_url
    ), allow_other_host: true
  end

  def reauth_callback
    if params[:error].present?
      redirect_to accounts_path, alert: "#{t('wise_items.reauth.failure_prefix')} #{params[:error_description].presence || params[:error]}"
      return
    end

    expected_state = session.delete(:wise_oauth_state)
    reauth_id = session.delete(:wise_oauth_reauth_id)
    unless expected_state.present? && params[:state].present? && ActiveSupport::SecurityUtils.secure_compare(expected_state.to_s, params[:state].to_s)
      redirect_to accounts_path, alert: t("wise_items.reauth.state_mismatch")
      return
    end

    wise_item = Current.family.wise_items.find_by(id: reauth_id) if reauth_id
    unless wise_item
      redirect_to accounts_path, alert: t("wise_items.reauth.not_found")
      return
    end

    # Match the redirect_uri we used in `reauth` so Wise doesn't reject the
    # token exchange for an unmatched callback. The token exchange goes
    # against the item's stored base URL so the new tokens are scoped to
    # the same environment as the original connection.
    redirect_uri = reauth_callback_wise_items_url
    provider = Provider::Wise.new(
      access_token: nil,
      base_url: wise_item.effective_base_url,
      auth_url: wise_item.effective_auth_url,
      client_id: Provider::Wise.oauth_client_id,
      client_secret: Provider::Wise.oauth_client_secret
    )
    token_payload = provider.exchange_code_for_token(code: params.require(:code), redirect_uri: redirect_uri).with_indifferent_access

    wise_item.update!(
      access_token: token_payload[:access_token],
      refresh_token: token_payload[:refresh_token].presence || wise_item.refresh_token,
      token_expires_at: token_payload[:expires_in].present? ? Time.current + token_payload[:expires_in].to_i.seconds : wise_item.token_expires_at,
      # If the item was previously configured with a personal API token
      # and an admin ran Reconnect, we now have a real OAuth grant. Flip
      # the mode so `wise_provider` uses the access token (and
      # `refresh_access_token_if_needed!` kicks in for future syncs)
      # instead of the stale personal_token. The personal_token column
      # is wiped so the encryption key isn't holding two credentials for
      # the same item.
      auth_mode: "oauth",
      personal_token: nil,
      status: :good
    )
    wise_item.sync_later

    redirect_to accounts_path, notice: t("wise_items.reauth.success")
  rescue Provider::Wise::WiseError => e
    redirect_to accounts_path, alert: "#{t('wise_items.reauth.failure_prefix')} #{e.message}"
  end

  private

    def set_wise_item
      @wise_item = Current.family.wise_items.find(params[:id])
    end

    def wise_item_params
      params.require(:wise_item).permit(:name, :personal_token, :sync_start_date, :base_url, :auth_url)
    end

    def fetch_wise_balances_if_needed
      return if @wise_item.wise_balances.any?
      return unless @wise_item.credentials_configured?

      @wise_item.import_latest_wise_data
    rescue Provider::Wise::WiseError => e
      @api_error = e.message
    end

    def provider_linked_account?(account)
      account.account_providers.exists? || account.plaid_account_id.present? || account.simplefin_account_id.present?
    end

    # Picks a per-balance default action and a default existing-account
    # id, both claim-aware: if multiple balances share a currency, each
    # row points at a distinct matching depository (when available) and
    # rows beyond the count of matching accounts default to "create".
    # Without the per-request claim tracker, the freshly rendered form
    # would suggest the same account for two link rows and the user
    # would have to fix the form before submitting.
    #
    # Returns [actions, account_ids] — both keyed by stringified
    # balance id.
    def compute_default_setup_actions(wise_balances, existing_accounts)
      actions = {}
      account_ids = {}
      claimed = Set.new

      wise_balances.each do |balance|
        match = existing_accounts.find { |acct| acct.currency == balance.currency && !claimed.include?(acct.id) }
        if match
          claimed << match.id
          actions[balance.id.to_s] = "link"
          account_ids[balance.id.to_s] = match.id
        else
          actions[balance.id.to_s] = "create"
        end
      end

      [ actions, account_ids ]
    end

    def respond_to_panel_success
      if turbo_frame_request?
        flash.now[:notice] = t("wise_items.update.success")
        @wise_items = Current.family.wise_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "wise-providers-panel",
            partial: "settings/providers/wise_panel",
            locals: { wise_items: @wise_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t("wise_items.update.success"), status: :see_other
      end
    end

    def respond_to_panel_error(message)
      @error_message = message
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "wise-providers-panel",
          partial: "settings/providers/wise_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        render :new, status: :unprocessable_entity
      end
    end

    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s
      uri = URI.parse(return_to)
      return nil if uri.scheme.present? || uri.host.present? || return_to.start_with?("//")
      return nil unless return_to.start_with?("/")

      return_to
    rescue URI::InvalidURIError
      nil
    end
end
