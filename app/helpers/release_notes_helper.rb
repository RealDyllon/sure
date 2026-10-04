module ReleaseNotesHelper
  def release_source_label(source)
    t("fork_releases.sources.#{source[:id]}")
  end

  def app_version_label
    if ForkRelease.version
      t("fork_releases.version", fork: ForkRelease.version.to_s, upstream: Sure.version.to_s)
    else
      t("fork_releases.upstream_version", version: Sure.version.to_s)
    end
  end

  def app_version_links
    upstream = link_to(t("fork_releases.upstream_version", version: Sure.version.to_s),
      "https://github.com/we-promise/sure/releases/tag/#{Sure.version.to_release_tag}", target: "_blank", rel: "noopener noreferrer", class: "hover:underline")
    return upstream unless ForkRelease.version

    fork = link_to(t("fork_releases.fork_version", version: ForkRelease.version.to_s),
      "https://github.com/#{ForkRelease.repository}/releases/tag/#{ForkRelease.tag}", target: "_blank", rel: "noopener noreferrer", class: "hover:underline")
    safe_join([ fork, " · ", t("fork_releases.based_on"), " ", upstream ])
  end

  def release_notes_body(notes)
    return t("fork_releases.no_notes") if notes[:body].blank?

    # GitHub release content is external input, including embedded raw HTML.
    html = sanitize(markdown(notes[:body]))
    return html unless notes[:repository].present? && notes[:tag].present?

    # Relative links in a release (such as the setup guide) belong to its
    # repository and tag, rather than to routes inside this Rails app.
    fragment = Nokogiri::HTML.fragment(html)
    base = "https://github.com/#{notes[:repository]}/blob/#{ERB::Util.url_encode(notes[:tag])}/"
    fragment.css("a[href], img[src]").each do |element|
      attribute = element.name == "a" ? "href" : "src"
      value = element[attribute]
      next if value.start_with?("#") || URI.parse(value).absolute?

      element[attribute] = URI.join(base, value).to_s
    rescue URI::InvalidURIError
      element.remove_attribute(attribute)
    end
    sanitize(fragment.to_html)
  end

  def release_title(notes)
    notes[:name].presence || notes[:tag]
  end
end
