require "test_helper"

class ReleaseNotesHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "release links resolve against their repository and tag while unsafe content is stripped" do
    notes = {
      repository: "RealDyllon/sure", tag: "fork-v0.1.0",
      body: "[Setup](docs/fork-rebuild.md) [GitHub](https://github.com) [Section](#setup) <img src='javascript:bad' onerror='bad()'> <script>bad()</script>"
    }
    html = Nokogiri::HTML.fragment(release_notes_body(notes))
    assert_equal "https://github.com/RealDyllon/sure/blob/fork-v0.1.0/docs/fork-rebuild.md", html.at_css("a")[:href]
    assert_equal "https://github.com", html.css("a")[1][:href]
    assert_equal "#setup", html.css("a")[2][:href]
    assert_empty html.css("script, [onerror], [src^='javascript:']")
  end

  test "version links identify each repository separately" do
    html = Nokogiri::HTML.fragment(app_version_links)
    assert_equal [ "Fork 0.1.0", "Sure 0.7.5-hotfix.1" ], html.css("a").map(&:text)
    assert_equal "https://github.com/RealDyllon/sure/releases/tag/fork-v0.1.0", html.css("a").first[:href]
    assert_equal "https://github.com/we-promise/sure/releases/tag/v0.7.5-hotfix.1", html.css("a").last[:href]
  end
end
