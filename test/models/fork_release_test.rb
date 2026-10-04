require "test_helper"

class ForkReleaseTest < ActiveSupport::TestCase
  test "fork version remains independent of upstream version" do
    assert_equal "0.1.0", ForkRelease.version.to_s
    assert_equal "fork-v0.1.0", ForkRelease.tag
    assert_equal "0.7.5-hotfix.1", Sure.version.to_s
  end

  test "missing or invalid fork version disables fork metadata" do
    root = mock
    path = mock
    root.stubs(:join).with(".fork-version").returns(path)
    Rails.stubs(:root).returns(root)
    path.stubs(:read).raises(Errno::ENOENT)
    assert_nil ForkRelease.tag
    path.stubs(:read).returns("not-a-version")
    assert_nil ForkRelease.tag
  end

  test "repository override rejects paths that are not owner and repository" do
    with_env_overrides("FORK_GITHUB_REPOSITORY" => "example/sure") do
      assert_equal "example/sure", ForkRelease.repository
    end
    with_env_overrides("FORK_GITHUB_REPOSITORY" => "https://github.com/example/sure") do
      assert_raises(ArgumentError) { ForkRelease.repository }
    end
  end
end
