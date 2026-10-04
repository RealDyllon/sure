require "test_helper"

class Provider::GithubTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Github.new
    @memory_cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@memory_cache)
    @client = mock
    @provider.stubs(:client).returns(@client)
  end

  test "exact lookup preserves Markdown without a rendering request" do
    @client.expects(:release_for_tag).with("we-promise/sure", "v1.0.0").returns(release("v1.0.0"))
    @client.expects(:markdown).never
    notes = @provider.fetch_release_notes("v1.0.0")
    assert_equal "v1.0.0", notes[:tag]
    assert_equal "# Notes", notes[:body]
    assert_equal "https://github.com/we-promise/sure/releases/tag/v1.0.0", notes[:url]
  end

  test "published history excludes drafts sorts by publication and limits results" do
    releases = 12.times.map { |i| release("v1.0.#{i}", published_at: i.days.ago, prerelease: i.zero?) }
    releases << release("v2.0.0", draft: true)
    @client.expects(:releases).with("we-promise/sure", per_page: 100).returns(releases.reverse)
    notes = @provider.fetch_recent_releases
    assert_equal 10, notes.size
    assert_equal "v1.0.0", notes.first[:tag]
    assert notes.first[:prerelease]
    assert_equal "v1.0.9", notes.last[:tag]
  end

  test "empty history is successful and cached" do
    @client.expects(:releases).once.returns([])
    assert_equal [], @provider.fetch_recent_releases
    assert_equal [], @provider.fetch_recent_releases
  end

  test "same tags and list requests in different repositories do not collide" do
    fork = Provider::Github.new(repository: "RealDyllon/sure")
    fork.stubs(:client).returns(@client)
    @client.expects(:release_for_tag).with("we-promise/sure", "v1.0.0").returns(release("v1.0.0", body: "upstream"))
    @client.expects(:release_for_tag).with("RealDyllon/sure", "v1.0.0").returns(release("v1.0.0", body: "fork"))
    @client.expects(:releases).with("we-promise/sure", per_page: 100).returns([])
    @client.expects(:releases).with("RealDyllon/sure", per_page: 100).returns([ release("fork-v0.1.0") ])
    assert_equal "upstream", @provider.fetch_release_notes("v1.0.0")[:body]
    assert_equal "fork", fork.fetch_release_notes("v1.0.0")[:body]
    assert_empty @provider.fetch_recent_releases
    assert_equal "fork-v0.1.0", fork.fetch_recent_releases.first[:tag]
  end

  test "failures are cached for five minutes and then retried" do
    @client.expects(:release_for_tag).twice.raises(Octokit::NotFound)
    assert_nil @provider.fetch_release_notes("v0.0.0")
    travel 4.minutes do
      assert_nil @provider.fetch_release_notes("v0.0.0")
    end
    travel 6.minutes do
      assert_nil @provider.fetch_release_notes("v0.0.0")
    end
  end

  test "successful histories expire after two hours" do
    @client.expects(:releases).twice.returns([])
    assert_empty @provider.fetch_recent_releases
    travel 119.minutes do
      assert_empty @provider.fetch_recent_releases
    end
    travel 121.minutes do
      assert_empty @provider.fetch_recent_releases
    end
  end

  test "missing and draft exact releases never produce notes" do
    @client.expects(:release_for_tag).with("we-promise/sure", "missing").once.returns(nil)
    @client.expects(:release_for_tag).with("we-promise/sure", "draft").once.returns(release("draft", draft: true))
    2.times do
      assert_nil @provider.fetch_release_notes("missing")
      assert_nil @provider.fetch_release_notes("draft")
    end
  end

  private
    def release(tag, **options)
      OpenStruct.new({ tag_name: tag, name: tag, body: "# Notes", author: nil, published_at: Time.current, draft: false, prerelease: false }.merge(options))
    end
end
