require "test_helper"

class CategoryCleanupGenerateJobTest < ActiveJob::TestCase
  setup do
    @family = families(:empty)
    @family.categories.destroy_all
    @user = users(:empty)
    @source = @family.categories.create!(name: "Example Root A", color: "#3b82f6", lucide_icon: "shapes")
    @target = @family.categories.create!(name: "Example Root B", color: "#3b82f6", lucide_icon: "shapes")
  end

  test "replayed job does not flip a reviewing run back to generating or wipe suggestions" do
    run = CategoryCleanupRun.create!(
      family: @family,
      user: @user,
      status: :reviewing,
      provider_name: "Fake LLM",
      model: "test-model"
    )
    # Pre-existing suggestions with user edits that must survive a worker restart.
    suggestion = run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: false, # user explicitly de-selected this
      new_name: "Example Renamed",
      status: :needs_review
    )
    # The run was previously processed by a job with id "stale-acked-job" — the
    # worker was restarted after moving the run to :reviewing but before
    # Sidekiq could ack the job. The replayed job will use the same job_id,
    # so processing_progress_job_matches? returns true on replay. The new
    # generating? guard must reject the claim.
    run.update!(
      processing_progress: {
        "phase" => "complete",
        "message" => "Category cleanup suggestions ready for review",
        "current" => 2,
        "total" => 2,
        "job_id" => "stale-acked-job",
        "retry_count" => 0,
        "last_updated_at" => 1.minute.ago.iso8601,
        "finished_at" => 1.minute.ago.iso8601
      }
    )

    # Stub a provider so GenerateSuggestions#call can run end-to-end if the
    # claim is incorrectly accepted. Without the generating? guard the claim
    # succeeds, GenerateSuggestions is invoked, and persist_suggestions!
    # wipes the user's existing suggestions and replaces them with the
    # provider's empty list — silently destroying review edits.
    fake_provider = Struct.new(:provider_name) do
      def organize_categories(categories:, model:, family:)
        Provider::Response.new(success?: true, data: [], error: nil)
      end
    end.new("Fake LLM")
    Provider::Registry.stubs(:default_llm_provider).returns(fake_provider)

    job = CategoryCleanupGenerateJob.new(run)
    job.define_singleton_method(:job_id) { "stale-acked-job" }
    job.perform(run)

    assert run.reload.reviewing?,
      "Run must stay in :reviewing; a replayed generation job must not claim a non-generating run"
    assert run.suggestions.exists?(suggestion.id),
      "Pre-existing suggestion must be preserved across a replayed job"
    assert_not run.suggestions.where(new_name: "Example Renamed").empty?,
      "User edits to suggestions must be preserved across a replayed job"
  end
end
