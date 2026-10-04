require "test_helper"

class ReleaseCatalogTest < ActiveSupport::TestCase
  setup do
    @fork, @upstream = ReleaseCatalog.sources
    @fork_provider = mock
    @upstream_provider = mock
    ReleaseCatalog.stubs(:provider_for).with(@fork).returns(@fork_provider)
    ReleaseCatalog.stubs(:provider_for).with(@upstream).returns(@upstream_provider)
  end

  test "includes installed release outside history without treating newer versions as installed" do
    newest = { tag: "fork-v0.2.0" }
    installed = { tag: @fork[:installed_tag] }
    @fork_provider.expects(:fetch_recent_releases).returns([ newest ])
    @fork_provider.expects(:fetch_release_notes).with(@fork[:installed_tag]).returns(installed)
    @upstream_provider.expects(:fetch_recent_releases).returns([ { tag: @upstream[:installed_tag] } ])
    @upstream_provider.expects(:fetch_release_notes).never
    histories = ReleaseCatalog.histories
    assert_equal [ newest, installed ], histories.first[:releases]
    refute histories.first[:installed_unavailable]
  end

  test "empty history and an outage remain distinguishable and independent" do
    @fork_provider.expects(:fetch_recent_releases).returns([])
    @fork_provider.expects(:fetch_release_notes).returns(nil)
    @upstream_provider.expects(:fetch_recent_releases).returns(nil)
    @upstream_provider.expects(:fetch_release_notes).returns({ tag: @upstream[:installed_tag] })
    fork, upstream = ReleaseCatalog.histories
    refute fork[:unavailable]
    assert_empty fork[:releases]
    assert upstream[:unavailable]
    assert_equal 1, upstream[:releases].size
  end

  test "popup fetches only pending installed releases and keeps the available source" do
    user = users(:family_admin)
    user.update!(preferences: {})
    @fork_provider.expects(:fetch_release_notes).with(@fork[:installed_tag]).returns(nil)
    @upstream_provider.expects(:fetch_release_notes).with(@upstream[:installed_tag]).returns({ body: "upstream" })
    assert_equal [ "upstream" ], ReleaseCatalog.pending_notes(user).pluck(:id)
    user.mark_release_seen!(@upstream[:installed_tag])
    @fork_provider.expects(:fetch_release_notes).with(@fork[:installed_tag]).returns({ body: "fork" })
    assert_equal [ "fork" ], ReleaseCatalog.pending_notes(user).pluck(:id)
  end
end
