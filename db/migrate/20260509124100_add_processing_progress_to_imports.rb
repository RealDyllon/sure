class AddProcessingProgressToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :processing_progress, :jsonb, null: false, default: {}
  end
end
