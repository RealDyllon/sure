require "test_helper"

class Planning::FireControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.to_h.merge("preview_features_enabled" => true))
    sign_in @user
    ensure_tailwind_build
  end

  test "FIRE page and roles form render inside Plan" do
    get plan_fire_url
    assert_response :success
    assert_select "form[data-turbo='false'] input[name='fire_profile[annual_spending_override]']"
    assert_select "select[name=?]", "fire_roles[#{accounts(:depository).id}]"
    assert_select "button[name='commit_mode'][value='preview']", text: I18n.t("fire.preview")
  end

  test "preview validates rates without persisting assumptions" do
    profile = FireProfile.for_user!(@user)
    patch plan_fire_url, params: { fire_profile: { annual_spending_override: 100, withdrawal_rate: 4 }, fire_roles: { accounts(:depository).id => "bridge" }, commit_mode: "preview" }
    assert_response :success
    assert_nil profile.reload.annual_spending_override
    patch plan_fire_url, params: { fire_profile: { withdrawal_rate: 0 }, commit_mode: "preview" }
    assert_response :unprocessable_entity
    assert_equal BigDecimal("0.04"), profile.reload.withdrawal_rate
  end

  test "saved assumptions normalize percentages and blank spending restores inference" do
    patch plan_fire_url, params: { fire_profile: { annual_spending_override: 100, withdrawal_rate: 4 }, commit_mode: "save" }
    assert_redirected_to plan_fire_url
    profile = FireProfile.for_user!(@user)
    assert_equal 100, profile.annual_spending_override
    patch plan_fire_url, params: { fire_profile: { annual_spending_override: "" }, commit_mode: "save" }
    assert_nil profile.reload.annual_spending_override
  end

  test "hidden accounts and arbitrary IDs cannot become FIRE overrides" do
    account = accounts(:depository)
    account.update!(status: :disabled)
    patch plan_fire_url, params: { fire_profile: { current_age: 30 }, fire_roles: { account.id => "bridge", "invalid" => "bridge" }, commit_mode: "save" }
    assert_empty FireProfile.for_user!(@user).account_role_overrides
  end

  test "preview-disabled users remain in upstream budgets" do
    @user.update!(preferences: @user.preferences.to_h.merge("preview_features_enabled" => false))
    get plan_fire_url
    assert_redirected_to budgets_path
  end
end
