require "test_helper"

class ReleaseHighlightsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: {})
  end

  test "pending tag when the deployed release is unseen" do
    assert_equal Sure.version.to_release_tag, ReleaseHighlights.pending_tag_for(@user)
  end

  test "no pending tag once the deployed release was seen" do
    @user.mark_release_seen!(Sure.version.to_release_tag)

    assert_nil ReleaseHighlights.pending_tag_for(@user)
  end

  test "pending tag returns when only a different release was seen" do
    @user.mark_release_seen!("v0.0.0-some-older-release")

    assert_equal Sure.version.to_release_tag, ReleaseHighlights.pending_tag_for(@user)
  end

  test "no pending tag without a user" do
    assert_nil ReleaseHighlights.pending_tag_for(nil)
  end

  test "unparseable local version yields no pending tag" do
    Sure.stubs(:version).raises(ArgumentError)

    assert_nil ReleaseHighlights.pending_tag_for(@user)
  end

  test "mark_release_seen! never regresses to an older tag" do
    @user.mark_release_seen!("v0.7.5-alpha.7")
    @user.mark_release_seen!("v0.7.4")

    assert_equal "v0.7.5-alpha.7", @user.reload.last_seen_release_tag
  end

  test "mark_release_seen! accepts a newer tag" do
    @user.mark_release_seen!("v0.7.4")
    @user.mark_release_seen!("v0.7.5-alpha.7")

    assert_equal "v0.7.5-alpha.7", @user.reload.last_seen_release_tag
  end

  test "mark_release_seen! rejects malformed tags" do
    assert_raises(ArgumentError) do
      @user.mark_release_seen!("not-a-release")
    end

    assert_nil @user.reload.last_seen_release_tag
  end

  test "mark_release_seen! recovers from a previously stored malformed tag" do
    @user.update!(preferences: { "last_seen_release_tag" => "not-a-release" })

    @user.mark_release_seen!("v0.7.5-alpha.7")

    assert_equal "v0.7.5-alpha.7", @user.reload.last_seen_release_tag
  end

  test "every release is eligible while the rollout is being tested" do
    assert ReleaseHighlights.eligible?(Semver.new("0.7.5-alpha.7"))
    assert ReleaseHighlights.eligible?(Semver.new("0.7.4"))
  end
  test "fork and upstream markers advance independently without losing preferences" do
    @user.update!(preferences: { "other" => "preserved" })
    @user.mark_releases_seen!("fork" => "fork-v0.2.0", "upstream" => Sure.version.to_release_tag)
    @user.mark_releases_seen!("fork" => "fork-v0.1.0", "upstream" => "v0.0.1")
    assert_equal "fork-v0.2.0", @user.reload.last_seen_fork_release_tag
    assert_equal Sure.version.to_release_tag, @user.last_seen_release_tag
    assert_equal "preserved", @user.preferences["other"]
    assert_empty ReleaseHighlights.pending_releases_for(@user)
  end

  test "rejects invalid pairs without partially updating either marker" do
    assert_raises(ArgumentError) { @user.mark_releases_seen!("upstream" => "v1.0.0", "fork" => "v1.0.0") }
    assert_raises(ArgumentError) { @user.mark_releases_seen!("unknown" => "v1.0.0") }
    assert_raises(ArgumentError) { @user.mark_releases_seen!({}) }
    assert_nil @user.reload.last_seen_release_tag
    assert_nil @user.last_seen_fork_release_tag
  end

  test "fork-only update is pending once upstream was seen" do
    @user.mark_release_seen!(Sure.version.to_release_tag)
    assert_equal({ "fork" => ForkRelease.tag }, ReleaseHighlights.pending_releases_for(@user))
  end
end
