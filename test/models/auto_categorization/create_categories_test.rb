require "test_helper"

class AutoCategorization::CreateCategoriesTest < ActiveSupport::TestCase
  include AutoCategorizationTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
  end

  test "does not queue generation if guarded finish loses job ownership" do
    run = create_auto_categorization_run(family: @family, user: @user, status: :creating_categories)
    run.category_suggestions.create!(
      name: "Example Bills",
      color: "#3b82f6",
      lucide_icon: "receipt",
      selected: true
    )
    run.update!(processing_progress: { "job_id" => "job-1", "phase" => "creating_categories" })
    run.expects(:finish_processing_progress!)
       .with(message: "Categories created", guard_job_id: "job-1")
       .returns(false)
    run.expects(:queue_generation!).never

    AutoCategorization::CreateCategories.call(run: run, job_id: "job-1")
  end
end
