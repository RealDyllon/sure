module WiseItem::Provided
  extend ActiveSupport::Concern

  def wise_provider
    Provider::Wise.new(
      access_token: oauth? ? access_token : personal_token,
      refresh_token: refresh_token,
      base_url: effective_base_url,
      auth_url: effective_auth_url,
      client_id: Provider::Wise.oauth_client_id,
      client_secret: Provider::Wise.oauth_client_secret
    )
  end
end
