# Rollout policy for the "What's new" release highlight popup.
#
# The popup is keyed to the exact deployed release tag (Sure.version), so it
# can never show or mark notes for a release the user is not actually running.
module ReleaseHighlights
  class << self
    # Which releases are worth highlighting.
    #
    # While the feature is being tested, every release - including alpha
    # prereleases - triggers the highlight. Once testing settles, switch this
    # predicate to stable-only (`!version.prerelease?`); nothing else needs
    # to change.
    def eligible?(version)
      true
    end

    # Tag of the deployed release the user has not seen yet, or nil when the
    # highlight should not be offered.
    def pending_tag_for(user)
      pending_releases_for(user)["upstream"]
    end

    def pending_releases_for(user)
      return {} unless user

      ReleaseCatalog.sources.each_with_object({}) do |source, pending|
        id = source.fetch(:id)
        tag = source.fetch(:installed_tag)
        version = user.parsed_release_tag_version!(tag, source: id)
        seen = id == "fork" ? user.last_seen_fork_release_tag : user.last_seen_release_tag
        seen_version = user.parsed_release_tag_version(seen, source: id)
        next if seen_version && seen_version >= version
        next unless eligible?(Semver.new(version.to_s))

        pending[id] = tag
      end
    rescue ArgumentError
      # Unparseable local version (e.g. "n/a: <sha>") - nothing to highlight.
      {}
    end
  end
end
