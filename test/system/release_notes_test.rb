require "application_system_test_case"

class ReleaseNotesTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.mark_releases_seen!("fork" => ForkRelease.tag, "upstream" => Sure.version.to_release_tag)
    @sources = ReleaseCatalog.sources
    @sources.each do |source|
      notes = { tag: source[:installed_tag], name: "#{source[:id].capitalize} release", body: "**Features from #{source[:id]}**", published_at: Time.current, prerelease: false }
      ReleaseCatalog.stubs(:provider_for).with(source).returns(stub(fetch_recent_releases: [ notes ], fetch_release_notes: notes))
    end
    sign_in @user
  end

  test "switches release history tabs using mouse and keyboard" do
    visit changelog_path
    assert_selector "[role=tab][aria-selected=true]", text: "Fork"
    assert_selector "[data-release-source=fork] details[open]", text: "Features from fork"
    assert_no_selector "[data-release-source=upstream]", visible: true
    find("[role=tab]", text: "Upstream").click
    assert_selector "[data-release-source=upstream] details[open]", text: "Features from upstream"
    assert_current_path changelog_path(source: "upstream")
    page.refresh
    assert_selector "[role=tab][aria-selected=true]", text: "Upstream"
    find("[role=tab]", text: "Upstream").send_keys(:home, :enter)
    assert_selector "[role=tab][aria-selected=true]", text: "Fork"
  end

  test "one combined popup dismisses both sources and stays dismissed after navigation" do
    @user.update!(preferences: {})
    visit root_path
    page.send_keys(:shift)
    assert_selector ".driver-popover [data-release-source=fork]", text: "Features from fork"
    assert_selector ".driver-popover [data-release-source=upstream]", text: "Features from upstream"
    find(".driver-popover-next-btn").click
    assert_no_selector ".driver-popover"
    # The dismissal is asynchronous; poll the persisted account state.
    Timeout.timeout(5) do
      sleep 0.05 until @user.reload.last_seen_fork_release_tag == ForkRelease.tag
    end
    assert_equal Sure.version.to_release_tag, @user.last_seen_release_tag
    visit changelog_path
    page.send_keys(:shift)
    assert_no_selector "[data-controller=release-highlight]"
    assert_no_selector ".driver-popover"
    visit root_path
    assert_no_selector "[data-controller=release-highlight]"
  end

  test "navigation without dismissal leaves notes pending and Escape acknowledges them" do
    @user.update!(preferences: {})
    visit root_path
    page.send_keys(:shift)
    assert_selector ".driver-popover"
    page.execute_script("Turbo.visit(#{changelog_path.to_json})")
    assert_selector "[data-testid=release-history]"
    assert_no_selector ".driver-popover"
    assert_nil @user.reload.last_seen_fork_release_tag
    assert_nil @user.last_seen_release_tag
    visit root_path
    page.send_keys(:shift)
    assert_selector ".driver-popover"
    page.send_keys(:escape)
    assert_no_selector ".driver-popover"
    Timeout.timeout(5) do
      sleep 0.05 until @user.reload.last_seen_fork_release_tag == ForkRelease.tag
    end
    assert_equal Sure.version.to_release_tag, @user.last_seen_release_tag
  end
end
