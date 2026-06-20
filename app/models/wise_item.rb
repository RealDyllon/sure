class WiseItem < ApplicationRecord
  include Syncable, WiseItem::Provided, WiseItem::Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good
  enum :auth_mode, { oauth: "oauth", personal_token: "personal_token" }, default: :oauth

  if encryption_ready?
    encrypts :access_token
    encrypts :refresh_token
    encrypts :personal_token
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :wise_balances, dependent: :destroy
  has_many :wise_cards, dependent: :destroy
  has_many :account_providers, through: :wise_balances
  has_many :accounts, through: :account_providers

  validates :name, presence: true
  validate :credentials_present

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> {
    active.where.not(access_token: nil).or(active.where.not(personal_token: nil))
  }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_wise_data
    WiseItem::Importer.new(self, wise_provider: wise_provider).import
  rescue Provider::Wise::WiseError => e
    update!(status: :requires_update) if e.error_type.in?(%i[unauthorized access_forbidden])
    raise
  end

  def process_accounts
    wise_balances.joins(:account_provider).find_each do |wise_balance|
      WiseBalance::Processor.new(wise_balance).process
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.visible.find_each do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  def upsert_wise_snapshot!(profiles_snapshot)
    profile = Array(profiles_snapshot).find { |p| p.with_indifferent_access[:id].to_s == profile_id.to_s } ||
              Array(profiles_snapshot).first
    profile_data = profile.to_h.with_indifferent_access

    assign_attributes(
      profile_id: profile_data[:id].presence || profile_id,
      profile_type: profile_data[:type].presence || profile_type,
      raw_payload: profiles_snapshot,
      raw_institution_payload: profile_data.presence || raw_institution_payload
    )

    self.name = profile_display_name if name.blank?
    save!
  end

  def refresh_access_token_if_needed!
    return false unless oauth?
    return false if refresh_token.blank?
    return false if token_expires_at.blank?
    return false if token_expires_at.present? && token_expires_at > 5.minutes.from_now

    token_payload = wise_provider.refresh_access_token
    data = token_payload.with_indifferent_access

    update!(
      access_token: data[:access_token],
      refresh_token: data[:refresh_token].presence || refresh_token,
      token_expires_at: data[:expires_in].present? ? Time.current + data[:expires_in].to_i.seconds : token_expires_at,
      status: :good
    )

    true
  end

  def credentials_configured?
    oauth? ? access_token.present? : personal_token.present?
  end

  def effective_base_url
    base_url.presence || Provider::Wise::DEFAULT_BASE_URL
  end

  def effective_auth_url
    auth_url.presence || Provider::Wise::DEFAULT_AUTH_URL
  end

  def linked_accounts_count
    wise_balances.joins(:account_provider).count
  end

  def unlinked_accounts_count
    wise_balances.requires_setup.count
  end

  def total_accounts_count
    wise_balances.count
  end

  def connected_institutions
    institutions = wise_balances
      .where.not(institution_metadata: nil)
      .map { |balance| balance.institution_metadata }
      .compact
      .uniq
    institutions = [ { "name" => "Wise", "domain" => "wise.com", "color" => "#00B9FF" } ] if institutions.empty?
    institutions
  end

  def institution_summary
    if wise_balances.any?
      "#{linked_accounts_count} of #{total_accounts_count} #{'balance'.pluralize(total_accounts_count)} linked"
    else
      connected_institutions.first&.dig("name") || "Wise"
    end
  end

  def sync_status_summary
    if total_accounts_count.zero?
      I18n.t("wise_items.wise_item.sync_status.no_balances")
    elsif unlinked_accounts_count.zero?
      I18n.t("wise_items.wise_item.sync_status.all_synced", count: linked_accounts_count)
    else
      I18n.t("wise_items.wise_item.sync_status.partial_sync",
        linked_count: linked_accounts_count,
        unlinked_count: unlinked_accounts_count)
    end
  end

  def profile_display_name
    data = raw_institution_payload.to_h.with_indifferent_access
    data[:fullName].presence || data[:name].presence || "Wise Connection"
  end

  private

    def credentials_present
      return if oauth? && access_token.present?
      return if personal_token? && personal_token.present?

      errors.add(:base, "Wise credentials are required")
    end
end
