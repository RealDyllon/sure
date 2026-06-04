require "test_helper"

class Provider::WiseAdapterTest < ActiveSupport::TestCase
  test "registers WiseBalance with provider factory" do
    Provider::Factory.ensure_adapters_loaded

    assert_includes Provider::Factory.registered_provider_types, "WiseBalance"
  end

  test "supports only depository accounts" do
    assert_equal [ "Depository" ], Provider::WiseAdapter.supported_account_types
  end

  test "does not add wise to pending providers for settled statement imports" do
    refute_includes Transaction::PENDING_PROVIDERS, "wise"
  end
end
