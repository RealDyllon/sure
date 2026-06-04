class WiseItemsController < ApplicationController
  before_action :set_wise_item, only: %i[show edit update destroy sync setup_accounts complete_account_setup]
  before_action :require_admin!, only: %i[
    new create oauth_start oauth_callback select_existing_account link_existing_account
    edit update destroy sync setup_accounts complete_account_setup
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
    @wise_item.name ||= "Wise Connection"
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
      redirect_to settings_providers_path, alert: "Wise OAuth is not configured. Set WISE_CLIENT_ID and WISE_CLIENT_SECRET."
      return
    end

    state = SecureRandom.hex(24)
    session[:wise_oauth_state] = state
    redirect_uri = Provider::Wise.oauth_redirect_uri.presence || oauth_callback_wise_items_url

    redirect_to Provider::Wise.oauth_authorize_url(redirect_uri: redirect_uri, state: state), allow_other_host: true
  end

  def oauth_callback
    if params[:error].present?
      redirect_to settings_providers_path, alert: "Wise authorization failed: #{params[:error_description].presence || params[:error]}"
      return
    end

    expected_state = session.delete(:wise_oauth_state)
    unless expected_state.present? && params[:state].present? && ActiveSupport::SecurityUtils.secure_compare(expected_state.to_s, params[:state].to_s)
      redirect_to settings_providers_path, alert: "Wise authorization state did not match. Please try again."
      return
    end

    redirect_uri = Provider::Wise.oauth_redirect_uri.presence || oauth_callback_wise_items_url
    provider = Provider::Wise.new(
      access_token: "",
      base_url: Provider::Wise::DEFAULT_BASE_URL,
      client_id: Provider::Wise.oauth_client_id,
      client_secret: Provider::Wise.oauth_client_secret
    )
    token_payload = provider.exchange_code_for_token(code: params.require(:code), redirect_uri: redirect_uri).with_indifferent_access

    wise_item = Current.family.wise_items.create!(
      name: "Wise Connection",
      auth_mode: "oauth",
      profile_id: params[:profileId].presence || params[:profile_id].presence,
      access_token: token_payload[:access_token],
      refresh_token: token_payload[:refresh_token],
      token_expires_at: token_payload[:expires_in].present? ? Time.current + token_payload[:expires_in].to_i.seconds : nil
    )
    wise_item.sync_later

    redirect_to accounts_path, notice: "Wise connected. Set up your Wise balances to finish."
  rescue Provider::Wise::WiseError => e
    redirect_to settings_providers_path, alert: "Wise authorization failed: #{e.message}"
  end

  def destroy
    @wise_item.unlink_all!(dry_run: false)
    @wise_item.destroy_later
    redirect_to accounts_path, notice: "Wise connection was unlinked."
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
  end

  def complete_account_setup
    balance_actions = params[:balance_actions] || {}
    existing_account_ids = params[:existing_account_ids] || {}
    created_or_linked = 0
    skipped = 0

    ActiveRecord::Base.transaction do
      balance_actions.each do |wise_balance_id, action|
        wise_balance = @wise_item.wise_balances.find_by(id: wise_balance_id)
        next unless wise_balance
        next if wise_balance.account_provider.present?

        case action
        when "create"
          account = Account.create_and_sync(
            {
              family: Current.family,
              name: wise_balance.name.presence || "Wise #{wise_balance.currency}",
              balance: wise_balance.current_balance || 0,
              currency: wise_balance.currency,
              accountable_type: "Depository",
              accountable_attributes: {}
            },
            skip_initial_sync: true
          )
          AccountProvider.create!(account: account, provider: wise_balance)
          wise_balance.clear_skipped!
          created_or_linked += 1
        when "link"
          account = Current.family.accounts.visible_manual.where(accountable_type: "Depository").find_by(id: existing_account_ids[wise_balance_id])
          next unless account
          next if provider_linked_account?(account)

          AccountProvider.create!(account: account, provider: wise_balance)
          wise_balance.clear_skipped!
          created_or_linked += 1
        else
          wise_balance.mark_skipped!
          skipped += 1
        end
      end
    end

    @wise_item.update!(pending_account_setup: @wise_item.unlinked_accounts_count.positive?)
    @wise_item.sync_later if created_or_linked.positive?

    flash[:notice] = if created_or_linked.positive?
      "#{created_or_linked} Wise #{'balance'.pluralize(created_or_linked)} set up."
    elsif skipped.positive?
      "Wise balances skipped."
    else
      "No Wise balances were changed."
    end

    redirect_to accounts_path, status: :see_other
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    if provider_linked_account?(@account)
      redirect_to accounts_path, alert: "This account is already linked to a provider."
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
    return redirect_to accounts_path, alert: "This account is already linked." if provider_linked_account?(account)
    return redirect_to accounts_path, alert: "Wise balance does not belong to this family." unless wise_balance.wise_item.family_id == Current.family.id
    return redirect_to accounts_path, alert: "Wise only supports depository account links." unless account.accountable_type == "Depository"
    return redirect_to accounts_path, alert: "This Wise balance is already linked." if wise_balance.account_provider.present?

    AccountProvider.create!(account: account, provider: wise_balance)
    wise_balance.clear_skipped!
    wise_balance.wise_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: "#{account.name} linked to Wise."
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

    def respond_to_panel_success
      if turbo_frame_request?
        flash.now[:notice] = "Wise configuration saved."
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
        redirect_to accounts_path, notice: "Wise configuration saved.", status: :see_other
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
      return nil if uri.scheme.present?
      return nil unless return_to.start_with?("/")

      return_to
    rescue URI::InvalidURIError
      nil
    end
end
