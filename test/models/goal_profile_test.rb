require "test_helper"

class GoalProfileTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
  end

  test "defaults to Singapore planning when the family is in Singapore" do
    @family.update!(country: "SG", currency: "SGD")

    profile = GoalProfile.find_or_create_for!(@user)

    assert_equal "singapore", profile.planning_region
    assert profile.singapore?
    assert_equal 55, profile.cpf_access_age
    assert_equal 65, profile.cpf_life_age
    assert_equal 63, profile.srs_access_age
    assert_equal 6, profile.emergency_fund_months
  end

  test "defaults to Singapore planning when the family currency is SGD" do
    @family.update!(country: "US", currency: "SGD")

    assert_equal "singapore", GoalProfile.find_or_create_for!(@user).planning_region
  end

  test "defaults to Singapore planning when CPF investment accounts are detected" do
    @family.update!(country: "US", currency: "USD")
    create_account(
      name: "Example CPF Ordinary Account",
      balance: 50_000,
      accountable: Investment.new(subtype: "cpf_ordinary")
    )

    assert_equal "singapore", GoalProfile.find_or_create_for!(@user).planning_region
  end

  test "CPF account detection only uses accounts included in the user's finances" do
    @family.update!(country: "US", currency: "USD")
    member = users(:family_member)
    cpf = create_account(
      name: "Example Private CPF Ordinary Account",
      balance: 50_000,
      accountable: Investment.new(subtype: "cpf_ordinary")
    )

    assert_equal "generic", GoalProfile.find_or_create_for!(member).planning_region

    AccountShare.create!(account: cpf, user: member, permission: "read_only", include_in_finances: true)

    assert_equal "singapore", GoalProfile.find_or_create_for!(member).reload.planning_region
  end

  test "defaults to generic planning without Singapore or CPF signals" do
    @family.update!(country: "US", currency: "USD")

    profile = GoalProfile.find_or_create_for!(@user)

    assert_equal "generic", profile.planning_region
    assert_not profile.singapore?
  end

  test "keeps an explicit planning region when account signals later change" do
    @family.update!(country: "US", currency: "USD")
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(planning_region: "generic")

    create_account(
      name: "Example CPF Special Account",
      balance: 70_000,
      accountable: Investment.new(subtype: "cpf_special")
    )

    assert_equal "generic", profile.reload.planning_region
  end

  test "keeps inferred planning region live until explicitly overridden" do
    @family.update!(country: "US", currency: "USD")
    profile = GoalProfile.find_or_create_for!(@user)

    assert_equal "generic", profile.planning_region

    @family.update!(currency: "SGD")

    assert_equal "singapore", profile.reload.planning_region

    profile.update!(planning_region: "generic")
    @family.update!(country: "SG")

    assert_equal "generic", profile.reload.planning_region
  end

  test "normalizes whole-number percentage assumptions" do
    profile = GoalProfile.new(
      family: @family,
      user: @user,
      planning_region: "generic",
      withdrawal_rate: 4,
      expected_return: 5,
      inflation_rate: 2
    )

    assert profile.valid?
    assert_equal BigDecimal("0.04"), profile.withdrawal_rate
    assert_equal BigDecimal("0.05"), profile.expected_return
    assert_equal BigDecimal("0.02"), profile.inflation_rate
  end

  test "persists skipped prompts" do
    profile = GoalProfile.find_or_create_for!(@user)

    profile.skip_prompt!("srs")

    assert profile.prompt_skipped?("srs")
    assert profile.reload.prompt_skipped?("srs")
  end

  test "uses manual spending override before inferred spending and can reset it" do
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(annual_spending_override: 48_000)

    assert_equal 48_000, profile.annual_spending(inferred: 36_000)

    profile.reset_assumption!(:annual_spending)

    assert_nil profile.reload.annual_spending_override
    assert_equal 36_000, profile.annual_spending(inferred: 36_000)
  end

  test "stores account-role overrides only for accounts included in the user's finances" do
    member = users(:family_member)
    shared_account = accounts(:depository)
    private_account = create_account(name: "Example Private Account", balance: 25_000)
    other_family_account = families(:empty).accounts.create!(
      owner: users(:empty),
      name: "Example Other Family Account",
      balance: 10_000,
      currency: "USD",
      accountable: Depository.new
    )
    profile = GoalProfile.find_or_create_for!(member)

    profile.update_account_role_overrides!(
      user: member,
      fire_roles: {
        shared_account.id => "bridge",
        private_account.id => "later",
        other_family_account.id => "excluded"
      },
      emergency_account_ids: [ shared_account.id, private_account.id, other_family_account.id ]
    )

    assert_equal({ shared_account.id => "bridge" }, profile.reload.fire_role_overrides)
    assert_equal [ shared_account.id ], profile.emergency_account_ids
  end

  test "filters stale account-role overrides when finance inclusion changes after save" do
    member = users(:family_member)
    shared_account = accounts(:depository)
    profile = GoalProfile.find_or_create_for!(member)
    profile.update_account_role_overrides!(
      user: member,
      fire_roles: { shared_account.id => "bridge" },
      emergency_account_ids: [ shared_account.id ]
    )

    account_shares(:depository_shared_with_member).update!(include_in_finances: false)

    assert_equal({}, profile.reload.fire_role_overrides)
    assert_equal [], profile.emergency_account_ids
  end

  private
    def create_account(name:, balance:, accountable: Depository.new, currency: @family.currency)
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
