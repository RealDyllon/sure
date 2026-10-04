require "test_helper"

class ReleaseHighlightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: {})
    ForkRelease.stubs(:version).returns(nil)
  end

  test "show renders the pending release notes" do
    release_notes = {
      avatar: nil,
      username: "we-promise",
      name: Sure.version.to_release_tag,
      published_at: Date.current,
      body: "Shiny new things"
    }
    github_provider = mock
    github_provider.expects(:fetch_release_notes).with(Sure.version.to_release_tag).returns(release_notes)
    ReleaseCatalog.stubs(:provider_for).returns(github_provider)

    get release_highlight_path

    assert_response :ok
    assert_select "h2", text: Sure.version.to_release_tag
    assert_select "p", text: "Shiny new things"
  end

  test "show returns no content once the deployed release was seen" do
    @user.mark_release_seen!(Sure.version.to_release_tag)

    github_provider = mock
    github_provider.expects(:fetch_release_notes).never
    ReleaseCatalog.stubs(:provider_for).returns(github_provider)

    get release_highlight_path

    assert_response :no_content
  end

  test "show returns no content when release notes are unavailable" do
    github_provider = mock
    github_provider.expects(:fetch_release_notes).returns(nil)
    ReleaseCatalog.stubs(:provider_for).returns(github_provider)

    get release_highlight_path

    assert_response :no_content
  end

  test "dismiss marks the given tag as seen" do
    patch release_highlight_dismiss_path, params: { tag: "v1.2.3" }, as: :json

    assert_response :ok
    assert_equal "v1.2.3", @user.reload.last_seen_release_tag
  end

  test "dismiss rejects malformed tags" do
    patch release_highlight_dismiss_path, params: { tag: "not-a-release" }, as: :json

    assert_response :unprocessable_entity
    assert_nil @user.reload.last_seen_release_tag
  end

  test "dismiss without a tag marks the deployed release as seen" do
    patch release_highlight_dismiss_path, as: :json

    assert_response :ok
    assert_equal Sure.version.to_release_tag, @user.reload.last_seen_release_tag
  end
  test "combined popup acknowledges exactly the displayed sources" do
    ForkRelease.unstub(:version)
    provider = stub(fetch_release_notes: { name: "New release", body: "**New features**" })
    ReleaseCatalog.stubs(:provider_for).returns(provider)
    get release_highlight_path
    assert_response :ok
    assert_select "section[data-release-source]", count: 2
    acknowledgement = JSON.parse(css_select("[data-release-acknowledgement]").first["data-release-acknowledgement"])
    patch release_highlight_dismiss_path, params: acknowledgement, as: :json
    assert_response :ok
    assert_equal ForkRelease.tag, @user.reload.last_seen_fork_release_tag
    assert_equal Sure.version.to_release_tag, @user.last_seen_release_tag
    get release_highlight_path
    assert_response :no_content
  end

  test "partial popup never marks unavailable fork notes as seen" do
    ForkRelease.unstub(:version)
    ReleaseCatalog.stubs(:provider_for).with(has_entries(id: "fork")).returns(stub(fetch_release_notes: nil))
    ReleaseCatalog.stubs(:provider_for).with(has_entries(id: "upstream")).returns(stub(fetch_release_notes: { name: "Upstream", body: "Notes" }))
    get release_highlight_path
    acknowledgement = JSON.parse(css_select("[data-release-acknowledgement]").first["data-release-acknowledgement"])
    assert_equal [ "upstream" ], acknowledgement.fetch("releases").keys
    patch release_highlight_dismiss_path, params: acknowledgement, as: :json
    assert_response :ok
    assert_nil @user.reload.last_seen_fork_release_tag
  end

  test "forged pairs and receipts from another account are rejected atomically" do
    ForkRelease.unstub(:version)
    ReleaseCatalog.stubs(:provider_for).returns(stub(fetch_release_notes: { name: "Release", body: "Notes" }))
    get release_highlight_path
    acknowledgement = JSON.parse(css_select("[data-release-acknowledgement]").first["data-release-acknowledgement"])
    forged = acknowledgement.deep_dup
    forged["releases"]["fork"] = "fork-v9.9.9"
    patch release_highlight_dismiss_path, params: forged, as: :json
    assert_response :unprocessable_entity
    assert_nil @user.reload.last_seen_release_tag
    assert_nil @user.last_seen_fork_release_tag
    sign_in users(:family_member)
    patch release_highlight_dismiss_path, params: acknowledgement, as: :json
    assert_response :unprocessable_entity
  end
  test "a receipt from an older tab cannot regress newer acknowledgements" do
    ForkRelease.unstub(:version)
    ReleaseCatalog.stubs(:provider_for).returns(stub(fetch_release_notes: { name: "Release", body: "Notes" }))
    get release_highlight_path
    acknowledgement = JSON.parse(css_select("[data-release-acknowledgement]").first["data-release-acknowledgement"])
    @user.mark_releases_seen!("fork" => "fork-v0.2.0", "upstream" => "v0.8.0")
    patch release_highlight_dismiss_path, params: acknowledgement, as: :json
    assert_response :ok
    assert_equal "fork-v0.2.0", @user.reload.last_seen_fork_release_tag
    assert_equal "v0.8.0", @user.last_seen_release_tag
  end

  test "expired receipts are rejected without updating markers" do
    ForkRelease.unstub(:version)
    ReleaseCatalog.stubs(:provider_for).returns(stub(fetch_release_notes: { name: "Release", body: "Notes" }))
    get release_highlight_path
    acknowledgement = JSON.parse(css_select("[data-release-acknowledgement]").first["data-release-acknowledgement"])
    travel 8.days do
      patch release_highlight_dismiss_path, params: acknowledgement, as: :json
      assert_response :unprocessable_entity
      assert_nil @user.reload.last_seen_release_tag
      assert_nil @user.last_seen_fork_release_tag
    end
  end
end
