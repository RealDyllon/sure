require "test_helper"

class GoalsAccountClassifierTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.accounts.update_all(status: "disabled")
    @family.update!(country: "SG", currency: "SGD")
    @profile = GoalProfile.find_or_create_for!(@user)
  end

  test "classifies CPF accounts into the later FIRE bucket in Singapore planning mode" do
    cash = create_account(name: "Example Cash Account", balance: 80_000, accountable: Depository.new)
    cpf = create_account(name: "Example CPF Ordinary Account", balance: 150_000, accountable: Investment.new(subtype: "cpf_ordinary"))

    result = Goals::AccountClassifier.new(user: @user, profile: @profile).call

    assert_includes result.fire_bridge_accounts, cash
    assert_includes result.fire_later_accounts, cpf
    assert_equal BigDecimal("80000"), result.fire_bridge_balance.amount
    assert_equal BigDecimal("150000"), result.fire_later_balance.amount
  end

  test "requires explicit SRS mapping and persists SRS not-applicable state" do
    srs = create_account(name: "Example SRS Account", balance: 60_000, accountable: Investment.new(subtype: "brokerage"))

    unmapped_result = Goals::AccountClassifier.new(user: @user, profile: @profile).call

    assert_not_includes unmapped_result.fire_later_accounts, srs
    assert_includes unmapped_result.review_prompts, :srs_mapping

    @profile.skip_prompt!("srs")
    skipped_result = Goals::AccountClassifier.new(user: @user, profile: @profile.reload).call

    assert_not_includes skipped_result.review_prompts, :srs_mapping

    @profile.set_fire_role!(srs, "later", user: @user)
    mapped_result = Goals::AccountClassifier.new(user: @user, profile: @profile.reload).call

    assert_includes mapped_result.fire_later_accounts, srs
  end

  test "does not show Singapore prompts in generic planning mode without Singapore signals" do
    @family.update!(country: "US", currency: "USD")
    @profile.update!(planning_region: "generic")

    result = Goals::AccountClassifier.new(user: @user, profile: @profile).call

    assert_not_includes result.review_prompts, :srs_mapping
    assert_not_includes result.review_prompts, :cpf_detected
  end

  test "keeps emergency inclusion separate from FIRE role classification" do
    account = create_account(name: "Example Emergency Cash", balance: 30_000, accountable: Depository.new)
    @profile.set_fire_role!(account, "bridge", user: @user)
    @profile.set_emergency_included_account_ids!([ account.id ], user: @user)

    result = Goals::AccountClassifier.new(user: @user, profile: @profile.reload).call

    assert_includes result.fire_bridge_accounts, account
    assert_includes result.emergency_accounts, account
  end

  test "rejects liability overrides from FIRE and emergency asset buckets" do
    credit_card = create_account(name: "Example Credit Card", balance: 4_000, accountable: CreditCard.new)
    @profile.set_fire_role!(credit_card, "bridge", user: @user)
    @profile.set_emergency_included_account_ids!([ credit_card.id ], user: @user)

    result = Goals::AccountClassifier.new(user: @user, profile: @profile.reload).call

    assert_not_includes result.fire_bridge_accounts, credit_card
    assert_not_includes result.fire_later_accounts, credit_card
    assert_includes result.fire_excluded_accounts, credit_card
    assert_not_includes result.emergency_accounts, credit_card
    assert_equal 0, result.fire_bridge_balance.amount
  end

  test "keeps illiquid asset types out of default bridge assets" do
    property = create_account(name: "Example Home", balance: 900_000, accountable: Property.new)
    vehicle = create_account(name: "Example Vehicle", balance: 30_000, accountable: Vehicle.new)
    other_asset = create_account(name: "Example Collectible", balance: 10_000, accountable: OtherAsset.new)

    result = Goals::AccountClassifier.new(user: @user, profile: @profile).call

    assert_not_includes result.fire_bridge_accounts, property
    assert_not_includes result.fire_bridge_accounts, vehicle
    assert_not_includes result.fire_bridge_accounts, other_asset
    assert_includes result.fire_excluded_accounts, property
    assert_includes result.fire_excluded_accounts, vehicle
    assert_includes result.fire_excluded_accounts, other_asset
  end

  test "surfaces unavailable FX for FIRE balances" do
    usd_account = create_account(name: "Example USD Brokerage", balance: 20_000, accountable: Investment.new(subtype: "brokerage"), currency: "USD")

    result = Goals::AccountClassifier.new(user: @user, profile: @profile).call

    assert_includes result.fire_bridge_accounts, usd_account
    assert result.fx_unavailable?
    assert_includes result.review_prompts, :fx_unavailable
    assert_equal 0, result.fire_bridge_balance.amount
  end

  test "excludes disabled and no-longer-included accounts from persisted mappings" do
    member = users(:family_member)
    shared_account = accounts(:depository)
    shared_account.update!(status: "active")
    disabled_account = create_account(name: "Example Disabled Account", balance: 10_000, accountable: Depository.new)
    disabled_account.disable!
    @profile = GoalProfile.find_or_create_for!(member)
    @profile.update_account_role_overrides!(
      user: member,
      fire_roles: { shared_account.id => "bridge", disabled_account.id => "later" },
      emergency_account_ids: [ shared_account.id, disabled_account.id ]
    )

    result = Goals::AccountClassifier.new(user: member, profile: @profile.reload).call

    assert_includes result.fire_bridge_accounts, shared_account
    assert_not_includes result.fire_later_accounts, disabled_account
    assert_equal [ shared_account.id ], @profile.emergency_account_ids
  end

  private
    def create_account(name:, balance:, accountable:, currency: @family.currency)
      @family.accounts.create!(
        owner: @user,
        name: name,
        balance: balance,
        cash_balance: balance,
        currency: currency,
        accountable: accountable
      )
    end
end
