require "test_helper"

class GoalsFireCalculatorTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.accounts.update_all(status: "disabled")
    @family.update!(country: "SG", currency: "SGD")
    @profile = GoalProfile.find_or_create_for!(@user)
    @profile.update!(
      current_age: 40,
      annual_spending_override: 40_000,
      withdrawal_rate: 0.04,
      expected_return: 0,
      inflation_rate: 0,
      cpf_access_age: 55,
      srs_access_age: 63
    )
  end

  test "computes target progress and headline progress from the limiting bucket" do
    create_account(name: "Example Bridge Cash", balance: 500_000, accountable: Depository.new)
    create_account(name: "Example CPF Ordinary Account", balance: 500_000, accountable: Investment.new(subtype: "cpf_ordinary"))

    result = Goals::FireCalculator.new(user: @user, profile: @profile, scenario: { annual_contribution: 100_000 }).call

    assert_equal BigDecimal("1000000"), result.fi_target_money.amount
    assert_equal BigDecimal("1.0"), result.later_retirement_progress
    assert_equal 41, result.estimated_fi_age
    assert_equal BigDecimal("560000"), result.bridge_target_money.amount
    assert_equal BigDecimal("0.8929"), result.bridge_progress.round(4)
    assert_equal result.bridge_progress, result.headline_progress
    assert_equal :bridge, result.limiting_constraint
  end

  test "delayed CPF and SRS assets never reduce the bridge target" do
    bridge = create_account(name: "Example Bridge Brokerage", balance: 50_000, accountable: Investment.new(subtype: "brokerage"))
    cpf = create_account(name: "Example CPF Special Account", balance: 600_000, accountable: Investment.new(subtype: "cpf_special"))
    srs = create_account(name: "Example SRS Account", balance: 300_000, accountable: Investment.new(subtype: "brokerage"))
    @profile.set_fire_role!(srs, "later", user: @user)

    result = Goals::FireCalculator.new(user: @user, profile: @profile.reload).call

    assert_includes result.bridge_accounts, bridge
    assert_includes result.later_accounts, cpf
    assert_includes result.later_accounts, srs
    assert_operator result.bridge_target_money.amount, :>, 0
    assert_equal BigDecimal("50000"), result.bridge_assets_money.amount
  end

  test "falls back to years-to-FI and prompts for age when age is missing" do
    @profile.update!(current_age: nil, birth_year: nil)
    create_account(name: "Example Bridge Cash", balance: 500_000, accountable: Depository.new)

    result = Goals::FireCalculator.new(user: @user, profile: @profile.reload, scenario: { annual_contribution: 100_000 }).call

    assert_nil result.estimated_fi_age
    assert_operator result.estimated_years_to_fi, :>, 0
    assert_includes result.review_prompts, :current_age_missing
  end

  test "uses SRS access age separately from CPF access age in milestones" do
    srs = create_account(name: "Example SRS Account", balance: 80_000, accountable: Investment.new(subtype: "brokerage"))
    @profile.set_fire_role!(srs, "later", user: @user)

    result = Goals::FireCalculator.new(user: @user, profile: @profile.reload).call

    assert_equal 55, result.milestones.fetch(:cpf_access_age)
    assert_equal 65, result.milestones.fetch(:cpf_life_age)
    assert_equal 63, result.milestones.fetch(:srs_access_age)
  end

  test "uses SRS access age for later SRS assets when sizing bridge need" do
    create_account(name: "Example Bridge Cash", balance: 1_000_000, accountable: Depository.new)
    srs = create_account(name: "Example SRS Account", balance: 80_000, accountable: Investment.new(subtype: "brokerage"))
    @profile.set_fire_role!(srs, "later", user: @user)

    result = Goals::FireCalculator.new(user: @user, profile: @profile.reload).call

    assert_equal 40, result.estimated_fi_age
    assert_equal BigDecimal("920000"), result.bridge_target_money.amount
  end

  test "applies return and inflation assumptions to FI timing projections" do
    @profile.update!(expected_return: 0.05, inflation_rate: 0.02)
    create_account(name: "Example Bridge Cash", balance: 900_000, accountable: Depository.new)

    result = Goals::FireCalculator.new(user: @user, profile: @profile.reload).call

    assert_equal 4, result.estimated_years_to_fi
    assert_equal 44, result.estimated_fi_age
  end

  test "scenario preview does not overwrite saved assumptions" do
    create_account(name: "Example Bridge Cash", balance: 250_000, accountable: Depository.new)

    result = Goals::FireCalculator.new(
      user: @user,
      profile: @profile,
      scenario: { annual_spending: 60_000, withdrawal_rate: 0.03 }
    ).call

    assert_equal BigDecimal("2000000"), result.fi_target_money.amount
    assert_equal BigDecimal("40000"), @profile.reload.annual_spending_override
    assert_equal BigDecimal("0.04"), @profile.withdrawal_rate
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
