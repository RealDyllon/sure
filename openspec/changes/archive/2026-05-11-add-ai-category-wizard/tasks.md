## 1. Data Model

- [x] 1.1 Add a migration that creates `auto_categorization_runs` with family/user references, status, provider/model metadata, counts, sanitized error text, `processing_progress` JSON, generation/apply timestamps, and indexes for active runs.
- [x] 1.2 Add a migration that creates `auto_categorization_run_transactions` with run, nullable entry/transaction/account references using nullify-on-delete behavior, immutable prompt-input snapshot JSON, captured timestamp, and run/status indexes.
- [x] 1.3 Add a migration that creates `auto_categorization_category_suggestions` with run, proposed name, normalized name, parent name, color, Lucide icon, rationale, selected flag, nullable created category reference, status, error metadata, and indexes for run filtering.
- [x] 1.4 Add a migration that creates `auto_categorization_suggestions` with run, run transaction, nullable suggested category, nullable selected category, suggested/selected category names, selected flag, status, reason/error metadata, applied timestamp, and indexes for run filtering.
- [x] 1.5 Implement `AutoCategorizationRun` associations, status enum, count helpers, retry/apply state guards, family/user scoping, and guarded `processing_progress` helpers for job ownership, stale detection, retry caps, and progress writes.
- [x] 1.6 Implement `AutoCategorizationRunTransaction` associations, immutable snapshot helpers, and stale live-record lookup helpers for entry, transaction, account access, and category lock checks.
- [x] 1.7 Implement `AutoCategorizationCategorySuggestion` associations, selected/category-name validations, normalization helpers, duplicate detection, review-state helpers, and idempotent category creation helpers.
- [x] 1.8 Implement `AutoCategorizationSuggestion` associations, selected/category validations, review-state helpers, and stale eligibility checks, and nullable FK handling for deleted categories/transactions.

## 2. Provider Contract

- [x] 2.1 Add `Provider::LlmConcept::SuggestedCategory = Data.define(:name, :parent_name, :color, :lucide_icon, :rationale)`.
- [x] 2.2 Add `Provider::LlmConcept#suggest_categories(transactions:, model: "", family: nil, json_mode: nil)` returning the existing `Provider::Response` wrapper.
- [x] 2.3 Implement `Provider::Openai#suggest_categories` using the same response/error wrapping and context-window batching conventions as `auto_categorize`; rely on `Provider::OpenaiViaCodex` inheritance where applicable.
- [x] 2.4 Implement starter category normalization that trims names, rejects blanks, de-dupes case-insensitively, validates/defaults colors and icons, prevents self-parenting, and enforces the existing two-level category limit.
- [x] 2.5 Ensure no-categories transaction generation never calls `auto_categorize` until at least one real family category exists.

## 3. Core Services

- [x] 3.1 Implement an eligibility query object that returns only transactions accessible to the initiating user, non-excluded, non-transfer, non-split-parent uncategorized transactions with unlocked `category_id`.
- [x] 3.2 Implement run creation that requires a configured default LLM provider, persists one snapshot row per eligible transaction with live nullable FKs plus immutable prompt input JSON, records empty-state counts, and avoids LLM calls when no eligible transactions exist.
- [x] 3.3 Implement starter category suggestion generation for families with no categories using `Provider::Registry.default_llm_provider.suggest_categories` against the eligible transaction snapshot.
- [x] 3.4 Persist starter category suggestions as reviewable rows, selected by default when valid, and create only selected/edited categories after user confirmation.
- [x] 3.5 Add no-categories fallbacks that let users manually add a starter category suggestion, retry starter generation, or create the default `Category.bootstrap!` set before transaction generation.
- [x] 3.6 Implement transaction suggestion generation using `Provider::Registry.default_llm_provider.auto_categorize` with transaction/category input built from run snapshots.
- [x] 3.7 Persist one transaction suggestion per snapshot row, including valid category matches as selected suggestions and missing/invalid/no-match provider results as unselected rows needing review.
- [x] 3.8 Implement apply logic that rechecks each selected suggestion, skips stale or invalid rows, updates only still-eligible transactions, calls `transaction.lock_attr!(:category_id)`, does not call `Entry.bulk_update!`, does not mark entries user-modified, and does not create AI `DataEnrichment` records.
- [x] 3.9 Record applied, skipped, and unchanged counts where unchanged means unselected or no-suggestion rows intentionally left untouched.

## 4. Jobs

- [x] 4.1 Add `AutoCategorizationGenerateJob` to route each run to starter category generation or chunked transaction suggestion generation and record queued/running/review/empty/failed status.
- [x] 4.2 Add `AutoCategorizationCreateCategoriesJob` to idempotently create reviewed starter categories, match existing normalized categories when present, prevent duplicate category creation, and then queue transaction suggestion generation.
- [x] 4.3 Add `AutoCategorizationApplyJob` to idempotently apply selected reviewed transaction suggestions, skip already-applied rows, and record applying/complete/failed status.
- [x] 4.4 Ensure jobs use app-owned retries with `job_id` ownership, guarded progress writes, retry caps, stale progress detection, `sidekiq_options retry: false` when appropriate, and no stale job overwrites.
- [x] 4.5 Ensure jobs store sanitized error messages and never create categories or commit transaction category changes before the relevant review step.
- [x] 4.6 Add a recovery job for stale runs, equivalent to the import stalled-processing pattern, that queues one retry when progress is stale and retry caps allow it.

## 5. Routes And Controllers

- [x] 5.1 Add routes for starting a run, showing the wizard, retrying generation, updating transaction suggestion review choices, and applying selected suggestions.
- [x] 5.2 Add routes for updating starter category suggestion review choices, manually adding starter category suggestions, creating default starter categories, and confirming category creation.
- [x] 5.3 Add a categories page action that shows the wizard entry point when the configured LLM provider is available, even if the family has no categories.
- [x] 5.4 Implement missing-provider guards as a no-run/no-job configuration response for start and retry; only existing in-flight jobs may fail with a sanitized provider-lost error.
- [x] 5.5 Implement controller guards for empty eligible scope, family ownership, account access, selected category family ownership, duplicate category creation/apply submissions, zero valid selected starter categories, and stale run states.
- [x] 5.6 Implement review filtering, searching, status/category/selected filters, and safe pagination using the app's existing `safe_per_page` pattern; preserve `request.query_parameters` across pagination, row updates, category overrides, polling refreshes, and apply navigation.

## 6. Wizard UI

- [x] 6.1 Build a wizard layout flow with Start, Suggest Categories, Review Categories, Suggest Transactions, Review Transactions, and Done steps, collapsing category setup when categories already exist.
- [x] 6.2 Build processing, chunked progress, empty, failed, retry, applying, and done states with clear counts and navigation back to Settings > Categories.
- [x] 6.3 Build the starter category review table with name, parent name, icon, color, rationale, selected checkbox, edit controls, manual-add controls, retry, default-category fallback, and disabled continue state when no valid category exists.
- [x] 6.4 Build the transaction review table with transaction snapshot details, live stale indicators, suggested category, selected checkbox, category override select, row status, and no-suggestion indicators.
- [x] 6.5 Add sticky bars that show selected category/transaction counts across all pages and disable continue/apply when no selected rows are valid.
- [x] 6.6 Add Turbo or Stimulus interactions for row selection/category updates without losing pagination or filter state; changing filters resets to page 1.

## 7. Tests

- [x] 7.1 Add model tests for run, run transaction snapshot, starter category suggestion, and transaction suggestion associations, validations, status transitions, counts, progress ownership, retry caps, and stale eligibility behavior.
- [x] 7.2 Add provider tests for the new starter category contract, OpenAI success/failure handling, invalid JSON/error handling, blank/duplicate names, invalid icon/color normalization, and no-categories guard against `auto_categorize`.
- [x] 7.3 Add service tests for eligibility filtering, account-access scoping, empty states, missing-provider no-run behavior, starter category provider success/failure, no usable starter suggestions, default-category fallback, transaction provider success, provider no-match rows, selected-by-default behavior, and generation using snapshot values after live transaction edits.
- [x] 7.4 Add apply service tests for selected-only updates, unselected unchanged rows, stale transaction skips, deleted category skips, access revocation skips, no `Entry#user_modified`, no AI `DataEnrichment`, and only `Transaction#locked_attributes["category_id"]` being set.
- [x] 7.5 Add job tests for starter category generation, idempotent category creation, chunked transaction generation with progress counts, apply status transitions, sanitized errors, failed retry with new `job_id`, stale old job overwrite prevention, duplicate create/apply submissions, recovery of stalled runs, and no pre-review commits.
- [x] 7.6 Add controller tests for start, show, retry, update starter category suggestion, manually add starter category suggestion, create default categories, create reviewed categories, update transaction suggestion, apply, family scoping, account access, filters, pagination, missing-provider states, and zero selected starter category guards.
- [x] 7.7 Add system tests covering launch from Categories with existing categories, launch with no categories, mocked starter category suggestions, empty starter response fallback, default-category fallback, category review, transaction suggestion review, cross-page selection/override, apply, and final transaction category results.
- [x] 7.8 Add a 100+ row review test, preferably 125 suggestions, that verifies pagination, filters, `per_page` clamping, DB-wide selected count, filter-state persistence, and no full-table render.

## 8. Verification

- [x] 8.1 Run targeted model, provider, service, job, controller, and system tests for the new wizard.
- [x] 8.2 Run `bin/rails test` or the narrowest reliable full-test subset required by the touched areas.
- [x] 8.3 Run `bin/rubocop` and fix offenses in changed Ruby files.
- [x] 8.4 Confirm no `spec/requests/api/v1/` rswag files are required because this change adds no public API endpoint.
