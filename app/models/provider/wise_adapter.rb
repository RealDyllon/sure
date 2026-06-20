class Provider::WiseAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("WiseBalance", self)

  def self.supported_account_types
    %w[Depository]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_wise?

    item = family.wise_items.active.ordered.first
    return [] unless item&.credentials_configured?

    # Wise is only exposed on the "Connect a new account" screen once
    # the family has a configured WiseItem (OAuth or personal token).
    # First-time OAuth starts from Settings > Providers, where the link
    # already targets `_top`. The account modal has no concept of a
    # top-level OAuth start, so we intentionally return no config here
    # until the item exists.
    [ {
      key: "wise",
      name: "Wise",
      description: "Set up a Wise currency balance",
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.setup_accounts_wise_item_path(item)
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_wise_items_path(account_id: account_id)
      }
    } ]
  end

  def self.build_provider(family: nil)
    return nil unless family.present?

    wise_item = family.wise_items.active.ordered.detect(&:credentials_configured?)
    wise_item&.wise_provider
  end

  def provider_name
    "wise"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_wise_item_path(item)
  end

  def item
    provider_account.wise_item
  end

  def institution_domain
    "wise.com"
  end

  def institution_name
    "Wise"
  end

  def institution_url
    "https://wise.com"
  end

  def institution_color
    "#00B9FF"
  end
end
