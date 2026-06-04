module Family::WiseConnectable
  extend ActiveSupport::Concern

  included do
    has_many :wise_items, dependent: :destroy
    has_many :wise_conversion_intentions, dependent: :destroy
  end

  def can_connect_wise?
    true
  end

  def has_wise_credentials?
    wise_items.active.any?(&:credentials_configured?)
  end
end
