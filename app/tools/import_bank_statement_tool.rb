# frozen_string_literal: true

# MCP tool wrapper for `Assistant::Function::ImportBankStatement`.
#
# Marked as non-read-only and destructive because it creates a new
# TransactionImport for the family.
class ImportBankStatementTool < ApplicationTool
  description Assistant::Function::ImportBankStatement.description

  annotations(
    title: "Import Bank Statement",
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: false,
    open_world_hint: true
  )

  arguments do
    required(:pdf_import_id).filled(:string).description("The ID of the PDF import to extract transactions from")
    optional(:account_id).filled(:string).description("The ID of the account to import transactions into. If not provided, will return available accounts.")
  end

  def self.function_class
    Assistant::Function::ImportBankStatement
  end
end
