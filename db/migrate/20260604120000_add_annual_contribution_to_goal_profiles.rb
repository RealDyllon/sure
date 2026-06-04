class AddAnnualContributionToGoalProfiles < ActiveRecord::Migration[7.2]
  def change
    add_column :goal_profiles, :annual_contribution, :decimal, precision: 19, scale: 4, default: 0, null: false
  end
end
