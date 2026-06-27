# frozen_string_literal: true

# MCP tool wrapper for `Assistant::Function::GetTransactions`.
class GetTransactionsTool < ApplicationTool
  description Assistant::Function::GetTransactions.description

  annotations(
    title: "Search Transactions",
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  arguments do
    required(:page).filled(:integer).description("Page number (1-indexed)")
    required(:order).filled(:string).description("Order of the transactions by date: 'asc' or 'desc'")
    optional(:search).filled(:string).description("Free-text search for transactions by name")
    optional(:amount).filled(:string).description("Amount for transactions (must be used with amount_operator)")
    optional(:amount_operator).filled(:string).description("Operator for amount: 'equal', 'less', or 'greater'")
    optional(:start_date).filled(:string).description("Start date for transactions in YYYY-MM-DD format")
    optional(:end_date).filled(:string).description("End date for transactions in YYYY-MM-DD format")
    optional(:accounts).array(:string).description("Filter transactions by account name")
    optional(:categories).array(:string).description("Filter transactions by category name")
    optional(:merchants).array(:string).description("Filter transactions by merchant name")
    optional(:tags).array(:string).description("Filter transactions by tag name")
  end

  def self.function_class
    Assistant::Function::GetTransactions
  end
end
