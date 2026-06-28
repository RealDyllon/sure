# frozen_string_literal: true

# MCP tool wrapper for `Assistant::Function::GetHoldings`.
class GetHoldingsTool < ApplicationTool
  description Assistant::Function::GetHoldings.description

  annotations(
    title: "List Investment Holdings",
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  arguments do
    required(:page).filled(:integer).description("Page number (1-indexed)")
    optional(:accounts).array(:string).description("Filter holdings by account name (only Investment and Crypto accounts are supported)")
    optional(:securities).array(:string).description("Filter holdings by security ticker symbol")
  end

  def self.function_class
    Assistant::Function::GetHoldings
  end
end
