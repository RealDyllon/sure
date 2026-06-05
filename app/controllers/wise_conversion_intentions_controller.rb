class WiseConversionIntentionsController < ApplicationController
  before_action :require_admin!
  before_action :set_intention, only: %i[refresh destroy]

  def create
    intention = Current.family.wise_conversion_intentions.build(intention_params)

    if intention.save
      begin
        intention.refresh_snapshot!
      rescue => e
        Rails.logger.warn("Wise conversion snapshot failed: #{e.class} - #{e.message}")
      end
      redirect_back_or_to accounts_path, notice: "Conversion plan saved."
    else
      redirect_back_or_to accounts_path, alert: intention.errors.full_messages.to_sentence
    end
  end

  def refresh
    @intention.refresh_snapshot!
    redirect_back_or_to accounts_path, notice: "Conversion plan refreshed."
  rescue => e
    redirect_back_or_to accounts_path, alert: "Could not refresh conversion plan: #{e.message}"
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
