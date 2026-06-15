require "test_helper"

class CategoryCleanupRunsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ensure_tailwind_build
    @user = users(:empty)
    @family = @user.family
    @family.categories.destroy_all
    @source = category!("Example Root A")
    @target = category!("Example Root B")
    sign_in @user
  end

  test "start requires configured provider and creates no run without one" do
    Provider::Registry.stubs(:default_llm_provider).returns(nil)

    assert_no_difference "CategoryCleanupRun.count" do
      post category_cleanup_runs_url
    end

    assert_redirected_to categories_url
  end

  test "start creates run and queues generation" do
    stub_category_cleanup_provider

    assert_difference "CategoryCleanupRun.count", 1 do
      assert_enqueued_with(job: CategoryCleanupGenerateJob) do
        post category_cleanup_runs_url
      end
    end

    assert_redirected_to category_cleanup_run_url(CategoryCleanupRun.last)
    assert_equal 2, CategoryCleanupRun.last.category_snapshot.size
  end

  test "updates review suggestion" do
    run = create_category_cleanup_run(status: :reviewing)
    suggestion = run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )

    patch suggestion_category_cleanup_run_url(run, suggestion),
      params: {
        suggested_action: "rename",
        new_name: "Example Root C",
        suggestion_selected: "true"
      }

    assert_redirected_to category_cleanup_run_url(run)
    suggestion.reload
    assert_equal "rename", suggestion.suggested_action
    assert_equal "Example Root C", suggestion.new_name
    assert_nil suggestion.target_category
    assert suggestion.selected?
  end

  test "updates reparent review suggestion metadata for selected parent" do
    run = create_category_cleanup_run(status: :reviewing)
    suggestion = run.suggestions.create!(
      source_category: @source,
      suggested_action: :rename,
      new_name: "Example Root C",
      selected: true
    )

    patch suggestion_category_cleanup_run_url(run, suggestion),
      params: {
        suggested_action: "reparent",
        parent_category_id: @target.id,
        suggestion_selected: "true"
      }

    assert_redirected_to category_cleanup_run_url(run)
    suggestion.reload
    assert_equal "reparent", suggestion.suggested_action
    assert_equal @target, suggestion.parent_category
    assert_not suggestion.metadata["reparent_intended_root"]
    assert_equal @target.id, suggestion.metadata["reparent_intended_parent_category_id"]
  end

  test "updates reparent review suggestion metadata for root move" do
    run = create_category_cleanup_run(status: :reviewing)
    suggestion = run.suggestions.create!(
      source_category: @source,
      parent_category: @target,
      suggested_action: :reparent,
      metadata: {
        "reparent_intended_root" => false,
        "reparent_intended_parent_category_id" => @target.id
      },
      selected: true
    )

    patch suggestion_category_cleanup_run_url(run, suggestion),
      params: {
        suggested_action: "reparent",
        parent_category_id: "",
        suggestion_selected: "true"
      }

    assert_redirected_to category_cleanup_run_url(run)
    suggestion.reload
    assert_nil suggestion.parent_category
    assert suggestion.metadata["reparent_intended_root"]
    assert_nil suggestion.metadata["reparent_intended_parent_category_id"]
  end

  test "does not update suggestion after review phase" do
    run = create_category_cleanup_run(status: :applying)
    suggestion = run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )

    patch suggestion_category_cleanup_run_url(run, suggestion),
      params: {
        suggested_action: "rename",
        new_name: "Example Root C",
        suggestion_selected: "true"
      }

    assert_redirected_to category_cleanup_run_url(run)
    assert_equal "This run is no longer editable.", flash[:alert]
    assert_equal "merge", suggestion.reload.suggested_action
  end

  test "apply queues selected actionable suggestions" do
    run = create_category_cleanup_run(status: :reviewing)
    run.suggestions.create!(
      source_category: @source,
      target_category: @target,
      suggested_action: :merge,
      selected: true
    )

    assert_enqueued_with(job: CategoryCleanupApplyJob) do
      post apply_category_cleanup_run_url(run)
    end

    assert_redirected_to category_cleanup_run_url(run)
    assert run.reload.applying?
  end

  private
    FakeProvider = Struct.new(:provider_name)

    def stub_category_cleanup_provider
      Provider::Registry.stubs(:default_llm_provider).returns(FakeProvider.new("Fake LLM"))
      Provider::Registry.stubs(:default_llm_model).returns("test-model")
    end

    def create_category_cleanup_run(status:)
      CategoryCleanupRun.create!(
        family: @family,
        user: @user,
        status: status,
        provider_name: "Fake LLM",
        model: "test-model"
      )
    end

    def category!(name, parent: nil)
      @family.categories.create!(
        name: name,
        parent: parent,
        color: "#3b82f6",
        lucide_icon: "shapes"
      )
    end
end
