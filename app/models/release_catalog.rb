# Combines independent GitHub histories without confusing published and installed
# versions. Nothing here reads financial data or makes GitHub calls in layouts.
class ReleaseCatalog
  class << self
    def sources
      sources = []
      sources << { id: "fork", repository: ForkRelease.repository, installed_tag: ForkRelease.tag } if ForkRelease.tag
      sources << { id: "upstream", repository: "we-promise/sure", installed_tag: Sure.version.to_release_tag }
      sources
    end

    def provider_for(source)
      Provider::Github.new(repository: source.fetch(:repository))
    end

    def histories
      sources.map do |source|
        provider = provider_for(source)
        recent = provider.fetch_recent_releases
        releases = recent || []
        installed = releases.find { |release| release[:tag] == source[:installed_tag] }
        installed ||= provider.fetch_release_notes(source[:installed_tag])
        releases = releases + [ installed ] if installed && releases.exclude?(installed)

        source.merge(releases: releases, unavailable: recent.nil?, installed_unavailable: installed.nil?)
      end
    end

    def pending_notes(user)
      pending = ReleaseHighlights.pending_releases_for(user)
      sources.filter_map do |source|
        next unless pending.key?(source[:id])

        notes = provider_for(source).fetch_release_notes(source[:installed_tag])
        source.merge(notes: notes) if notes
      end
    end
  end
end
