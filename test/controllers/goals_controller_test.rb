require "test_helper"

class GoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    ensure_tailwind_build
  end

  test "English locale keys exist for the Goals UI" do
    expected_translations = {
      "layouts.application.nav.goals" => "Goals",
      "goals.index.title" => "Goals",
      "goals.fire.title" => "Financial Independence",
      "goals.fire.card.title" => "Financial Independence",
      "goals.fire.card.review_assumptions" => "Review assumptions",
      "goals.assumptions.title" => "Goal assumptions",
      "goals.assumptions.current_age" => "Current age"
    }

    expected_translations.each do |key, expected|
      assert_equal expected, I18n.t(key, locale: :en), "unexpected translation for #{key}"
    end
  end

  test "dashboard renders the Goals surface" do
    get goals_path

    assert_response :ok
    assert_select "h1", text: "Goals"
    assert_select "[data-testid='fire-hero']"
  end

  test "dashboard renders review prompts and supports skipping the SRS prompt" do
    @family.update!(country: "SG", currency: "SGD")
    @family.accounts.create!(
      owner: @user,
      name: "Example SRS Account",
      balance: 20_000,
      cash_balance: 20_000,
      currency: "SGD",
      accountable: Investment.new(subtype: "brokerage")
    )

    get goals_path

    assert_response :ok
    assert_select "[data-testid='goals-review-prompts']", text: /SRS account detected/

    patch skip_prompt_goals_account_mappings_path, params: { prompt: "srs" }

    assert_redirected_to goals_path
    assert GoalProfile.find_by!(user: @user).prompt_skipped?("srs")
  end

  test "FIRE detail renders assumptions and timeline" do
    get goals_fire_path

    assert_response :ok
    assert_select "h1", text: "Financial Independence"
    assert_select "[data-testid='fire-timeline']"
    assert_select "[data-testid='fire-assumptions']"
  end

  test "assumptions page exposes all editable saved assumptions" do
    get goals_assumptions_path

    assert_response :ok
    assert_select "input[name='goal_profile[birth_year]']"
    assert_select "input[name='goal_profile[cpf_life_age]']"
    assert_select "input[name='goal_profile[savings_rate_target]']"
  end

  test "assumption updates persist profile changes" do
    patch goals_assumptions_path, params: {
      goal_profile: {
        planning_region: "singapore",
        current_age: 38,
        annual_spending_override: 72_000,
        withdrawal_rate: 3.5,
        cpf_access_age: 55,
        srs_access_age: 63,
        emergency_fund_months: 9
      }
    }

    assert_redirected_to goals_path
    profile = GoalProfile.find_by!(user: @user)
    assert_equal "singapore", profile.planning_region
    assert_equal 38, profile.current_age
    assert_equal BigDecimal("72000"), profile.annual_spending_override
    assert_equal BigDecimal("0.035"), profile.withdrawal_rate
    assert_equal 9, profile.emergency_fund_months
  end

  test "assumption update renders validation errors" do
    patch goals_assumptions_path, params: {
      goal_profile: {
        withdrawal_rate: ""
      }
    }

    assert_response :unprocessable_entity
    assert_select "h1", text: "Goal assumptions"
    assert_select ".text-destructive", text: /Withdrawal rate/
  end

  test "account mapping update rejects inaccessible accounts" do
    inaccessible = families(:empty).accounts.create!(
      owner: users(:empty),
      name: "Example Other Family Account",
      balance: 10_000,
      currency: "USD",
      accountable: Depository.new
    )

    patch goals_account_mappings_path, params: {
      fire_roles: { inaccessible.id => "later" },
      emergency_account_ids: [ inaccessible.id ]
    }

    assert_redirected_to goals_path
    profile = GoalProfile.find_by!(user: @user)
    assert_empty profile.fire_role_overrides
    assert_empty profile.emergency_account_ids
  end

  test "account mapping update keeps valid accounts when invalid accounts are submitted" do
    valid_account = accounts(:depository)
    inaccessible = families(:empty).accounts.create!(
      owner: users(:empty),
      name: "Example Other Family Account",
      balance: 10_000,
      currency: "USD",
      accountable: Depository.new
    )

    patch goals_account_mappings_path, params: {
      fire_roles: { valid_account.id => "bridge", inaccessible.id => "later" },
      emergency_account_ids: [ valid_account.id, inaccessible.id ]
    }

    assert_redirected_to goals_path
    profile = GoalProfile.find_by!(user: @user)
    assert_equal({ valid_account.id => "bridge" }, profile.fire_role_overrides)
    assert_equal [ valid_account.id ], profile.emergency_account_ids
  end

  test "scenario preview does not save assumptions" do
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(annual_spending_override: 48_000)

    post preview_goals_fire_path, params: { scenario: { annual_spending: 60_000, withdrawal_rate: 3.5 } }

    assert_response :ok
    assert_equal BigDecimal("48000"), profile.reload.annual_spending_override
  end
end
