## Why

Users can have hundreds of uncategorized transactions after imports or account syncs, but the existing AI auto-categorization path commits changes immediately. Settings > Categories needs a review-first workflow that uses the configured LLM provider while keeping users in control before categories are applied.

## What Changes

- Add an AI auto-categorization wizard launched from Settings > Categories.
- Generate category suggestions for eligible uncategorized transactions using `Provider::Registry.default_llm_provider`, matching the provider path used by PDF import.
- When the family has no categories, infer a starter category set from the eligible uncategorized transactions, present those category suggestions for review, create approved categories, and then continue into transaction categorization.
- Persist suggestion runs with a durable per-transaction snapshot so large batches can be generated, reviewed, retried, and reported asynchronously from a stable input set.
- Present suggestions in a paginated, filterable table that supports hundreds of rows.
- Default valid AI suggestions to selected, leave no-suggestion rows unselected, and allow per-row category overrides before commit.
- Apply only selected suggestions with direct transaction category updates and `category_id` locks, treating applied categories as user-approved choices without bulk entry updates.
- Report generation, skipped-row, applied, failed, and empty-state outcomes without committing partial changes before the review step.

## Capabilities

### New Capabilities
- `ai-category-wizard`: Review-first AI categorization for uncategorized transactions from Settings > Categories.

### Modified Capabilities

None.

## Impact

- Adds Rails models, migrations, jobs, controllers, and views for AI categorization runs, durable transaction snapshots, starter category suggestions, and transaction category suggestions.
- Reuses the existing LLM provider registry, category data, transaction enrichment locks, pagination, and wizard/import-style UI conventions.
- Adds Minitest model, job, controller, and system coverage.
- Does not add or modify public API endpoints, so no OpenAPI rswag artifacts are required.
