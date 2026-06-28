# frozen_string_literal: true

# MCP tool wrapper for `Assistant::Function::SearchFamilyFiles`.
class SearchFamilyFilesTool < ApplicationTool
  description Assistant::Function::SearchFamilyFiles.description

  annotations(
    title: "Search Family Files",
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: true
  )

  arguments do
    required(:query).filled(:string).description("The search query to find relevant information in the family's uploaded documents")
    optional(:max_results).filled(:integer).description("Maximum number of results to return (default: 10, max: 20)")
  end

  def self.function_class
    Assistant::Function::SearchFamilyFiles
  end
end
