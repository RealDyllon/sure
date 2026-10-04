class Provider::Github
  attr_reader :name, :owner, :branch, :client

  def initialize(repository: "we-promise/sure")
    raise ArgumentError, "invalid GitHub repository" unless repository.match?(/\A[\w.-]+\/[\w.-]+\z/)

    @owner, @name = repository.split("/")
    @branch = "main"
    @client = Octokit::Client.new(
      connection_options: {
        request: {
          open_timeout: 10,
          timeout: 10
        }
      }
    )
  end

  def fetch_latest_release_notes
    fetch_recent_releases&.first
  end

  # [] means a successful empty history; nil means GitHub was unavailable.
  # Inspect up to 100 records so drafts do not normally shorten the list.
  def fetch_recent_releases(limit: 10)
    fetch_cached_release_notes("recent/#{limit}") do
      releases = client.releases(repo, per_page: 100).reject(&:draft)
      releases.sort_by { |release| release.published_at || Time.at(0) }
        .reverse.first(limit).map { |release| serialize_release_notes(release) }
    end
  end

  # Release notes for one exact release tag (e.g. "v0.7.5-alpha.7"), so the
  # "What's new" highlight always reflects the deployed build rather than
  # whatever happens to be the newest release on GitHub.
  def fetch_release_notes(tag)
    fetch_cached_release_notes("tag/#{tag}") do
      release = client.release_for_tag(repo, tag)
      serialize_release_notes(release) if release && !release.draft
    end
  end

  private
    def repo
      "#{owner}/#{name}"
    end

    # Caches both hits (2h) and misses/failures (5min, as a false sentinel):
    # without the sentinel, a missing tag or GitHub outage would retry the
    # outbound call on every user's first interaction of every page.
    def fetch_cached_release_notes(cache_key)
      cache_key = "github_release_notes/v2/#{repo}/#{cache_key}"
      cached = Rails.cache.read(cache_key)
      return cached == false ? nil : cached unless cached.nil?

      notes = yield
      Rails.cache.write(cache_key, notes.nil? ? false : notes, expires_in: notes.nil? ? 5.minutes : 2.hours)
      notes
    rescue => e
      Rails.logger.error "Failed to fetch GitHub release notes (#{cache_key}): #{e.message}"
      Rails.cache.write(cache_key, false, expires_in: 5.minutes)
      nil
    end

    def serialize_release_notes(release)
      {
        avatar: release.author&.avatar_url,
        # this is the username, it would be nice to get the full name
        username: release.author&.login,
        name: release.name,
        repository: repo,
        tag: release.tag_name,
        url: "https://github.com/#{repo}/releases/tag/#{ERB::Util.url_encode(release.tag_name)}",
        prerelease: release.prerelease,
        published_at: release.published_at,
        body: release.body
      }
    end
end
