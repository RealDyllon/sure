class ReleaseHighlightsController < ApplicationController
  # The "What's new" popup content: release notes for the deployed release
  # the current account has not seen yet. Fetched lazily on the user's first
  # interaction so ordinary page renders never hit the GitHub API.
  def show
    @release_sections = ReleaseCatalog.pending_notes(Current.user)

    if @release_sections.any?
      releases = @release_sections.to_h { |source| [ source[:id], source[:installed_tag] ] }
      @acknowledgement = {
        releases: releases,
        receipt: verifier.generate({ "user_id" => Current.user.id, "releases" => releases }, expires_in: 7.days)
      }
      render :show, layout: false
    else
      head :no_content
    end
  end

  # Marks the release's highlight as seen for the current account. The
  # client passes the tag it displayed; when absent we fall back to the
  # currently deployed tag.
  def dismiss
    if params.key?(:releases)
      receipt = verifier.verified(params[:receipt])
      releases = params[:releases].is_a?(ActionController::Parameters) ? params[:releases].to_unsafe_h : nil
      raise ArgumentError, "invalid release receipt" unless receipt && receipt["user_id"] == Current.user.id && receipt["releases"] == releases

      Current.user.mark_releases_seen!(releases)
    else
      tag = params[:tag].presence || Sure.version.to_release_tag
      Current.user.mark_release_seen!(tag)
    end

    head :ok
  rescue ArgumentError
    head :unprocessable_entity
  end

  private
    def verifier
      Rails.application.message_verifier("release_highlights")
    end
end
