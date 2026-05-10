require "test_helper"

class AutoCategorizationGenerateJobTest < ActiveJob::TestCase
  include AutoCategorizationTestHelper
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.accounts.each { |account| account.entries.delete_all }
  end

  test "stale job does not overwrite newer progress" do
    entry = create_transaction(account: accounts(:depository), name: "Example Cafe")
    run = create_auto_categorization_run(family: @family, user: @user, status: :suggesting_transactions)
    create_run_transaction(run, entry)
    run.update!(processing_progress: { "job_id" => "newer-job", "message" => "Newer retry owns this run" })

    stub_default_llm_provider(
      AutoCategorizationTestHelper::FakeLlmProvider.new(
        categorizations: [
          Provider::LlmConcept::AutoCategorization.new(transaction_id: "unused", category_name: "Food & Drink")
        ]
      )
    )

    AutoCategorizationGenerateJob.perform_now(run)

    assert_equal "newer-job", run.reload.processing_progress["job_id"]
    assert_equal "Newer retry owns this run", run.processing_progress["message"]
    assert_equal 0, run.suggestions.count
  end

  test "recovery queues retry for stalled runs below retry cap" do
    run = create_auto_categorization_run(family: @family, user: @user, status: :suggesting_transactions)
    run.update!(
      processing_progress: {
        "job_id" => "stalled-job",
        "retry_count" => 0,
        "last_updated_at" => 10.minutes.ago.iso8601,
        "phase" => "suggesting_transactions"
      }
    )

    assert_enqueued_with(job: AutoCategorizationGenerateJob) do
      RecoverStalledAutoCategorizationRunsJob.perform_now
    end
  end

  test "retry replaces stale job ownership before enqueuing replacement job" do
    run = create_auto_categorization_run(family: @family, user: @user, status: :suggesting_transactions)
    run.update!(
      processing_progress: {
        "job_id" => "stalled-job",
        "retry_count" => 0,
        "last_updated_at" => 10.minutes.ago.iso8601,
        "phase" => "suggesting_transactions"
      }
    )

    assert_enqueued_with(job: AutoCategorizationGenerateJob) do
      assert run.queue_retry!
    end

    assert_not_equal "stalled-job", run.reload.processing_progress["job_id"]
    assert_equal 1, run.processing_progress["retry_count"]
  end

  test "retry for stalled category creation queues category creation job" do
    run = create_auto_categorization_run(family: @family, user: @user, status: :creating_categories)
    run.category_suggestions.create!(
      name: "Example Bills",
      color: "#3b82f6",
      lucide_icon: "receipt",
      selected: true
    )
    run.update!(
      processing_progress: {
        "job_id" => "stalled-job",
        "retry_count" => 0,
        "last_updated_at" => 10.minutes.ago.iso8601,
        "phase" => "creating_categories"
      }
    )

    assert_enqueued_with(job: AutoCategorizationCreateCategoriesJob) do
      assert run.queue_retry!
    end

    assert_not_equal "stalled-job", run.reload.processing_progress["job_id"]
    assert_equal "creating_categories", run.processing_progress["phase"]
    assert_equal 1, run.processing_progress["retry_count"]
  end

  test "apply queue replaces completed generation job ownership" do
    category = @family.categories.create!(name: "Example Coffee", color: "#22c55e", lucide_icon: "coffee")
    entry = create_transaction(account: accounts(:depository), name: "Example Cafe")
    run = create_auto_categorization_run(family: @family, user: @user, status: :reviewing_transactions)
    run_transaction = create_run_transaction(run, entry)
    run.suggestions.create!(
      run_transaction: run_transaction,
      selected_category: category,
      selected: true,
      status: :suggested
    )
    run.update!(
      processing_progress: {
        "job_id" => "generation-job",
        "phase" => "complete",
        "message" => "Transaction suggestions ready for review"
      }
    )

    assert_enqueued_with(job: AutoCategorizationApplyJob) do
      assert run.queue_apply!
    end

    assert_not_equal "generation-job", run.reload.processing_progress["job_id"]
    assert_equal "applying", run.processing_progress["phase"]
  end

  test "queued apply job claims fresh ownership and completes run" do
    category = @family.categories.create!(name: "Example Coffee", color: "#22c55e", lucide_icon: "coffee")
    entry = create_transaction(account: accounts(:depository), name: "Example Cafe")
    run = create_auto_categorization_run(family: @family, user: @user, status: :reviewing_transactions)
    run_transaction = create_run_transaction(run, entry)
    run.suggestions.create!(
      run_transaction: run_transaction,
      selected_category: category,
      selected: true,
      status: :suggested
    )
    run.update!(
      processing_progress: {
        "job_id" => "generation-job",
        "phase" => "complete",
        "message" => "Transaction suggestions ready for review"
      }
    )

    perform_enqueued_jobs do
      assert run.queue_apply!
    end

    assert run.reload.complete?
    assert_equal category, entry.transaction.reload.category
  end
end
