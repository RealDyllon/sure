# frozen_string_literal: true

# MCP tool wrapper for `Assistant::Function::GetAccounts`.
class GetAccountsTool < ApplicationTool
  description Assistant::Function::GetAccounts.description

  annotations(
    title: "List Accounts",
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  def self.function_class
    Assistant::Function::GetAccounts
  end
end
