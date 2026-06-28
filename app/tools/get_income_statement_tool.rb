# frozen_string_literal: true

# MCP tool wrapper for `Assistant::Function::GetIncomeStatement`.
class GetIncomeStatementTool < ApplicationTool
  description Assistant::Function::GetIncomeStatement.description

  annotations(
    title: "Get Income Statement",
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  arguments do
    required(:start_date).filled(:string).description("Start date for aggregation period in YYYY-MM-DD format")
    required(:end_date).filled(:string).description("End date for aggregation period in YYYY-MM-DD format")
  end

  def self.function_class
    Assistant::Function::GetIncomeStatement
  end
end
