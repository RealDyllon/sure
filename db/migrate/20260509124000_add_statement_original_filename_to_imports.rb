class AddStatementOriginalFilenameToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :statement_original_filename, :string
  end
end
