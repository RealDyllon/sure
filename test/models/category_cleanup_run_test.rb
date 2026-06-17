require "test_helper"

class CategoryCleanupRunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:empty)
    @family.categories.destroy_all
    @user = users(:empty)
    @source = @family.categories.create!(name: "Example Root A", color: "#3b82f6", lucide_icon: "shapes")
    @target = @family.categories.create!(name: "Example Root B", color: "#3b82f6", lucide_icon: "shapes")
  end

  test "queue_retry! enqueues apply job from stale applying run" do
    run = CategoryCleanupRun.create!(
      family: @family,
      user: @user,
      status: :applying,
      provider_name: "Fake LLM",
      model: "test-model",
      processing_progress: {
        phase: "applying",
        message: "Applying reviewed category cleanup",
        current: 0,
        total: 1,
        job_id: "stale-job-id",
        retry_count: 0,
        last_updated_at: 10.minutes.ago.iso8601
      }
    )
    run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )

    assert_enqueued_with(job: CategoryCleanupApplyJob) do
      assert run.queue_retry!
    end

    assert_equal 1, run.reload.processing_progress["retry_count"]
    assert run.applying?
  end

  test "queue_apply! rejects cyclic merge selections and keeps run reviewing" do
    run = CategoryCleanupRun.create!(
      family: @family,
      user: @user,
      status: :reviewing,
      provider_name: "Fake LLM",
      model: "test-model"
    )
    run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )
    run.suggestions.create!(
      source_category: @target,
      target_category: @source,
      suggested_action: :merge,
      selected: true
    )

    assert_no_enqueued_jobs do
      assert_not run.queue_apply!
    end

    assert run.reload.reviewing?
    assert_match(/cycle/i, run.error)
  end
end
