# frozen_string_literal: true

# MCP tool wrapper for `Assistant::Function::GetBalanceSheet`.
class GetBalanceSheetTool < ApplicationTool
  description Assistant::Function::GetBalanceSheet.description

  annotations(
    title: "Get Balance Sheet",
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  def self.function_class
    Assistant::Function::GetBalanceSheet
  end
end
