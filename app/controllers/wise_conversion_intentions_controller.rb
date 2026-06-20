class WiseConversionIntentionsController < ApplicationController
  before_action :require_admin!
  before_action :set_intention, only: %i[refresh destroy]

  def create
    intention = Current.family.wise_conversion_intentions.build(intention_params)

    if intention.save
      # Initial snapshot is a best-effort convenience: a row without a
      # provider_rate is still useful state for the user, and the form
      # surfaces a follow-up notice if the rate came back blank.
      begin
        intention.refresh_snapshot!
      rescue => e
        Rails.logger.warn("Wise conversion snapshot failed: #{e.class} - #{e.message}")
      end

      notice = if intention.latest_snapshot&.provider_rate.blank?
        "Conversion plan saved, but the initial exchange rate could not be fetched. Click Refresh to try again."
      else
        "Conversion plan saved."
      end

      redirect_back_or_to accounts_path, notice: notice
    else
      redirect_back_or_to accounts_path, alert: intention.errors.full_messages.to_sentence
    end
  end

  def refresh
    # Manual refresh is the user's explicit "try again". If the rate
    # provider is down, surface that to the user and leave any existing
    # snapshots untouched — never insert a blank-rate row that would
    # look like a fresh successful sync.
    rate = @intention.current_exchange_rate_or_nil
    if rate.nil?
      redirect_back_or_to accounts_path, alert: "Could not refresh conversion plan: exchange rate lookup failed. Please try again later."
      return
    end

    @intention.create_snapshot_with_rate(rate)
    redirect_back_or_to accounts_path, notice: "Conversion plan refreshed."
  end

  def destroy
    @intention.destroy!
    redirect_back_or_to accounts_path, notice: "Conversion plan deleted."
  end

  private

    def set_intention
      @intention = Current.family.wise_conversion_intentions.find(params[:id])
    end

    def intention_params
      params.require(:wise_conversion_intention).permit(
        :source_account_id,
        :source_currency,
        :target_currency,
        :target_amount,
        :deadline_on,
        :trip_starts_on,
        :trip_ends_on,
        :desired_rate,
        :notes
      )
    end
end
