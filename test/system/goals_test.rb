require "application_system_test_case"

class GoalsTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
  end

  test "opens Goals from main navigation and reviews FIRE assumptions" do
    visit root_path

    all("a[href='#{goals_path}']", text: "Goals", minimum: 1).first.click

    assert_current_path goals_path
    assert_text "Goals"
    assert_text "Financial Independence"

    goals_link = all("a[href='#{goals_path}']", text: "Goals", minimum: 1).first
    within goals_link do
      assert_selector ".bg-nav-indicator", visible: :all
    end

    click_on "Review assumptions"

    assert_text "Goal assumptions"
    assert_field "Current age"
  end

  test "mobile navigation includes Goals" do
    page.current_window.resize_to(390, 844)

    visit root_path

    within "[data-viewport-target='bottomNav']" do
      assert page.evaluate_script("document.querySelector('[data-viewport-target=\"bottomNav\"]').scrollWidth <= document.querySelector('[data-viewport-target=\"bottomNav\"]').clientWidth")
      click_on "Goals"
    end

    assert_current_path goals_path
  end
end
