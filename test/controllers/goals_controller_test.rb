require "test_helper"

class GoalsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    ensure_tailwind_build
  end

  test "English locale keys exist for the Goals UI" do
    expected_translations = {
      "layouts.application.nav.goals" => "Goals",
      "goals.index.title" => "Goals",
      "goals.index.subtitle" => "Estimated progress toward financial independence and other goals.",
      "goals.fire.title" => "Financial Independence",
      "goals.fire.card.title" => "Financial Independence",
      "goals.fire.card.review_assumptions" => "Review assumptions",
      "goals.fire.card.view_details" => "View details",
      "goals.fire.card.headline_progress" => "Headline progress",
      "goals.fire.card.estimated_fi_target" => "Estimated FIRE target",
      "goals.fire.card.bridge_assets" => "Bridge assets",
      "goals.fire.card.later_assets" => "Later assets",
      "goals.fire.timeline.title" => "Timeline",
      "goals.fire.assumptions.title" => "Assumptions",
      "goals.fire.scenario.title" => "Scenario",
      "goals.fire.scenario.preview" => "Preview scenario",
      "goals.fire.scenario.save" => "Save scenario",
      "goals.assumptions.title" => "Goal assumptions",
      "goals.assumptions.current_age" => "Current age",
      "goals.assumptions.planning_region_default" => "Default (auto-detect)",
      "goals.assumptions.fire_role_srs_later" => "Later (SRS)",
      "goals.assumptions.account_treatment" => "Account treatment",
      "goals.assumptions.save" => "Save",
      "goals.emergency_fund.title" => "Emergency fund",
      "goals.emergency_fund.subtitle" => "Estimated cash runway using selected cash-like accounts.",
      "goals.emergency_fund.current" => "Current: %{months} months",
      "goals.emergency_fund.target" => "Target: %{amount}",
      "goals.emergency_fund.target_html" => "Target: <span class=\"privacy-sensitive\">%{amount}</span>",
      "goals.debt_payoff.title" => "Debt payoff",
      "goals.debt_payoff.subtitle" => "Reliable debt balances only; available-credit style values are flagged for review.",
      "goals.debt_payoff.estimated_months" => "Estimated payoff: %{months} months",
      "goals.debt_payoff.loan_terms_note" => "Based on original loan terms.",
      "goals.debt_payoff.payment_fx_unavailable" => "Can't convert payment currency: %{name}.",
      "goals.debt_payoff.balance_only" => "Balance only",
      "goals.debt_payoff.review_accounts.one" => "Review %{count} account",
      "goals.debt_payoff.review_accounts.other" => "Review %{count} accounts",
      "goals.savings_rate.title" => "Savings rate",
      "goals.savings_rate.subtitle" => "Estimated from recent income and expenses.",
      "goals.savings_rate.insufficient_history" => "Insufficient recent history",
      "goals.custom_goals.title" => "Custom goals",
      "goals.custom_goals.empty" => "Add a target amount and choose the accounts that fund it.",
      "goals.custom_goals.name" => "Goal name",
      "goals.custom_goals.add" => "Add goal",
      "goals.custom_goals.update" => "Update goal",
      "goals.custom_goals.archive" => "Archive",
      "goals.review_prompts.srs_mapping" => "SRS account detected. Review whether it should unlock at the SRS access age."
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

  test "dashboard renders the emergency fund target with a privacy-sensitive span via the _html locale key" do
    @family.update!(country: "SG", currency: "SGD")
    @family.accounts.update_all(status: "disabled")
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(annual_spending_override: 48_000, emergency_fund_months: 6)

    get goals_path

    assert_response :ok
    # Uses the _html variant of the key, so the span is rendered as HTML
    # (not as escaped text). SGD formats as "$S24,000.00".
    assert_select "span.privacy-sensitive", text: /\$S24,000\.00/
  end

  test "dashboard renders the loan-terms caveat under the debt payoff estimate when loans are present" do
    @family.update!(currency: "SGD")
    @family.accounts.update_all(status: "disabled")
    @family.accounts.create!(
      owner: @user,
      name: "Example Fixed Loan",
      balance: 12_000,
      cash_balance: 12_000,
      currency: "SGD",
      accountable: Loan.new(subtype: "other", term_months: 12, interest_rate: 0, rate_type: "fixed")
    )

    get goals_path

    assert_response :ok
    assert_match(/Estimated payoff: \d+ months/, response.body)
    assert_match(/Based on original loan terms/, response.body)
  end

  test "dashboard does not render the loan-terms caveat when the debt is credit-card only" do
    @family.update!(currency: "SGD")
    @family.accounts.update_all(status: "disabled")
    @family.accounts.create!(
      owner: @user,
      name: "Example Card With Minimum",
      balance: 4_000,
      cash_balance: 4_000,
      currency: "SGD",
      accountable: CreditCard.new(minimum_payment: 200)
    )

    get goals_path

    assert_response :ok
    assert_match(/Estimated payoff: \d+ months/, response.body)
    assert_no_match(/Based on original loan terms/, response.body)
  end

  test "dashboard renders an edit form for saved custom goals" do
    goal = FinancialGoal.create!(
      family: @family,
      user: @user,
      goal_type: "custom",
      name: "Example Existing Goal",
      target_amount: 12_000,
      target_currency: "USD",
      target_date: 1.year.from_now.to_date
    )

    get goals_path

    assert_response :ok
    assert_select "form[action='#{financial_goal_path(goal)}']" do
      assert_select "input[name='_method'][value='patch']"
      assert_select "input[name='financial_goal[name]'][value='Example Existing Goal']"
      assert_select "input[name='financial_goal[target_amount]'][value='12000.0']"
      assert_select "input[name='financial_goal[target_currency]'][value='USD']"
      assert_select "input[type='submit'][value='Update goal']"
    end
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

  test "dashboard renders savings rate target and unavailable FX warning" do
    @family.update!(country: "SG", currency: "SGD")
    @family.accounts.update_all(status: "disabled")
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(savings_rate_target: 0.5)
    account = @family.accounts.create!(
      owner: @user,
      name: "Example Spending Account",
      balance: 5_000,
      cash_balance: 5_000,
      currency: "SGD",
      accountable: Depository.new
    )
    create_transaction(account: account, name: "Example Salary", amount: -8_000, currency: "SGD", date: 1.month.ago)
    create_transaction(account: account, name: "Example Groceries", amount: 2_000, currency: "SGD", date: 1.month.ago)
    create_transaction(account: account, name: "Example Foreign Expense", amount: 1_000, currency: "USD", date: 1.month.ago)

    get goals_path

    assert_response :ok
    assert_select "article", text: /Savings rate.*Target: 50%/m
    assert_select "article", text: /Savings rate.*Progress: 150%/m
    assert_select "article", text: /Savings rate.*Some cashflow needs exchange rates/m
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
    assert_select "input[name='goal_profile[annual_contribution]']"
    assert_select "option[value='srs_later']", text: "Later (SRS)"
  end

  test "assumptions page preserves inferred planning mode as auto-detect" do
    @family.update!(country: "US", currency: "USD")
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(planning_region: nil)

    get goals_assumptions_path

    assert_response :ok
    assert_select "select[name='goal_profile[planning_region]'] option[value=''][selected]", text: "Default (auto-detect)"
  end

  test "assumption updates do not persist inferred planning mode accidentally" do
    @family.update!(country: "US", currency: "USD")
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(planning_region: nil)

    patch goals_assumptions_path, params: {
      goal_profile: {
        planning_region: "",
        current_age: 39,
        withdrawal_rate: 0.04,
        expected_return: 0.05,
        inflation_rate: 0.02,
        cpf_access_age: 55,
        cpf_life_age: 65,
        srs_access_age: 63,
        emergency_fund_months: 6
      }
    }

    assert_redirected_to goals_path
    assert_nil profile.reload[:planning_region]
    assert_equal "generic", profile.planning_region
  end

  test "account mappings form renders default emergency accounts checked before override" do
    @family.accounts.update_all(status: "disabled")
    cash = @family.accounts.create!(
      owner: @user,
      name: "Example Emergency Cash",
      balance: 5_000,
      cash_balance: 5_000,
      currency: @family.currency,
      accountable: Depository.new
    )
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(account_role_overrides: {})

    get goals_assumptions_path

    assert_response :ok
    assert_select "input[type='checkbox'][name='emergency_account_ids[]'][value='#{cash.id}'][checked]"
  end

  test "assumption updates persist profile changes" do
    patch goals_assumptions_path, params: {
      goal_profile: {
        planning_region: "singapore",
        current_age: 38,
        annual_spending_override: 72_000,
        annual_contribution: 18_000,
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
    assert_equal BigDecimal("18000"), profile.annual_contribution
    assert_equal BigDecimal("0.035"), profile.withdrawal_rate
    assert_equal 9, profile.emergency_fund_months
  end

  test "blank annual contribution in a full assumptions form falls back to zero" do
    patch goals_assumptions_path, params: {
      goal_profile: {
        planning_region: "generic",
        current_age: 40,
        annual_spending_override: 48_000,
        annual_contribution: "",
        withdrawal_rate: 4,
        cpf_access_age: 55,
        cpf_life_age: 65,
        srs_access_age: 63,
        emergency_fund_months: 6
      }
    }

    assert_redirected_to goals_path
    profile = GoalProfile.find_by!(user: @user)
    assert_equal 0, profile.annual_contribution
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
    profile.update!(annual_spending_override: 48_000, annual_contribution: 12_000)

    post preview_goals_fire_path, params: { scenario: { annual_spending: 60_000, withdrawal_rate: 3.5, annual_contribution: 24_000 } }

    assert_response :ok
    assert_select "input[name='scenario[annual_spending]'][value='60000']"
    assert_select "input[name='scenario[withdrawal_rate]'][value='3.5']"
    assert_select "input[name='scenario[annual_contribution]'][value='24000']"
    assert_equal BigDecimal("48000"), profile.reload.annual_spending_override
    assert_equal BigDecimal("12000"), profile.annual_contribution
  end

  test "scenario save persists assumptions" do
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(annual_spending_override: 48_000, withdrawal_rate: 0.04, annual_contribution: 12_000)

    post save_scenario_goals_fire_path, params: {
      scenario: {
        annual_spending: 60_000,
        withdrawal_rate: 3.5,
        annual_contribution: 24_000
      }
    }

    assert_redirected_to goals_fire_path
    profile.reload
    assert_equal BigDecimal("60000"), profile.annual_spending_override
    assert_equal BigDecimal("0.035"), profile.withdrawal_rate
    assert_equal BigDecimal("24000"), profile.annual_contribution
  end

  test "scenario save with blank annual spending clears the override" do
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(annual_spending_override: 48_000, withdrawal_rate: 0.04, annual_contribution: 12_000)

    post save_scenario_goals_fire_path, params: {
      scenario: {
        annual_spending: "",
        withdrawal_rate: 4,
        annual_contribution: 12_000
      }
    }

    assert_redirected_to goals_fire_path
    assert_nil profile.reload.annual_spending_override
    assert_equal BigDecimal("0.04"), profile.withdrawal_rate
    assert_equal BigDecimal("12000"), profile.annual_contribution
  end

  test "scenario save with blank withdrawal rate surfaces a validation error" do
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(withdrawal_rate: 0.04, annual_contribution: 12_000)

    post save_scenario_goals_fire_path, params: {
      scenario: {
        annual_spending: 60_000,
        withdrawal_rate: "",
        annual_contribution: 24_000
      }
    }

    assert_response :unprocessable_entity
    assert_select "h1", text: "Financial Independence"
    assert_equal BigDecimal("0.04"), profile.reload.withdrawal_rate
  end

  test "scenario save with blank annual contribution falls back to zero" do
    profile = GoalProfile.find_or_create_for!(@user)
    profile.update!(annual_spending_override: 48_000, withdrawal_rate: 0.04, annual_contribution: 12_000)

    post save_scenario_goals_fire_path, params: {
      scenario: {
        annual_spending: 60_000,
        withdrawal_rate: 4,
        annual_contribution: ""
      }
    }

    assert_redirected_to goals_fire_path
    assert_equal BigDecimal("60000"), profile.reload.annual_spending_override
    assert_equal BigDecimal("0.04"), profile.withdrawal_rate
    assert_equal 0, profile.annual_contribution
  end
end
