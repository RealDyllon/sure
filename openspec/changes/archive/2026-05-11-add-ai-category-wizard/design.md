## Context

The app already has two relevant categorization paths:

- `Family::AutoCategorizer` calls `Provider::Registry.default_llm_provider.auto_categorize` and immediately writes `Transaction#category_id` as an AI enrichment.
- `Transactions::CategorizesController` gives users a manual quick-categorize wizard for accessible, uncategorized, non-transfer transactions.

The new wizard must combine those strengths: use the configured LLM provider from the PDF import path, but persist suggestions for review before any transaction categories are changed. The implementation must handle hundreds of rows without one large request, one long untracked job, or one large rendered page.

The no-categories case is part of the main flow. If a family has no categories, the wizard should not stop at "create categories first"; it should ask the configured LLM to inspect the eligible transaction snapshot and propose a starter category set, then let the user review and create those categories before transaction-level suggestions are generated.

## Goals / Non-Goals

**Goals:**

- Let users launch AI categorization from Settings > Categories when a default LLM provider is configured.
- Suggest starter categories from uncategorized transactions when the family has no categories.
- Generate suggestions asynchronously for eligible uncategorized transactions.
- Persist runs, durable transaction snapshots, starter category suggestions, and transaction suggestions so users can review, filter, paginate, retry, and apply later.
- Apply only user-selected suggestions and lock applied category choices as user-approved.
- Skip stale rows safely when transactions, categories, or account access change after the run starts.

**Non-Goals:**

- Do not create runs, enqueue jobs, or call the LLM when no default LLM provider is configured.
- Do not auto-create categories from AI output without review.
- Do not suggest category bootstrapping when the family already has categories; use the existing category set for transaction suggestions.
- Do not categorize transfer, excluded, split-parent, hidden-account, already categorized, inaccessible-account, or locked-category transactions.
- Do not add API endpoints or OpenAPI documentation.
- Do not replace the existing quick-categorize wizard or rule-based AI auto-categorization path.

## Decisions

1. Use persisted run, snapshot, and suggestion records.

   Create `AutoCategorizationRun`, `AutoCategorizationRunTransaction`, `AutoCategorizationCategorySuggestion`, and `AutoCategorizationSuggestion` instead of storing suggestions in session or form payloads. This supports background generation, stable LLM inputs, large result sets, category setup, pagination, retry, stale-row checks, and an auditable done screen.

   `AutoCategorizationRun#status` should include `draft`, `suggesting_categories`, `reviewing_categories`, `creating_categories`, `suggesting_transactions`, `reviewing_transactions`, `applying`, `complete`, `empty`, and `failed`. Run columns should include `family_id`, `user_id`, `status`, `provider_name`, `model`, count columns for category suggestions, transaction suggestions, selected rows, applied rows, skipped rows, unchanged rows, `error`, `processing_progress` JSON, `started_at`, `finished_at`, and JSON `metadata`.

   `AutoCategorizationRunTransaction` should include `run_id`, nullable `entry_id`, nullable `transaction_id`, nullable `account_id`, `snapshot` JSON, and `captured_at`. The snapshot stores the exact prompt input fields used for LLM calls: date, name or description, notes, amount, currency, classification, merchant name, transaction kind, and any normalized metadata included in prompts. Live FKs should use nullify-on-delete behavior so stale rows can still be reviewed and counted.

   `AutoCategorizationCategorySuggestion` should include `run_id`, `name`, `normalized_name`, `parent_name`, `color`, `lucide_icon`, `rationale`, `selected`, nullable `created_category_id`, `status`, and `error`. Category creation should be idempotent: if `created_category_id` is already present, skip; if a matching normalized family category now exists, attach it and mark the row `matched_existing`.

   `AutoCategorizationSuggestion` should include `run_id`, `run_transaction_id`, nullable `suggested_category_id`, nullable `selected_category_id`, `suggested_category_name`, `selected_category_name`, `selected`, `status`, `reason`, `error`, and `applied_at`. Suggested and selected category FKs should be nullable with nullify-on-delete behavior, and apply must revalidate category IDs against `run.family.categories`.

2. Scope eligibility to transactions accessible to the initiating user.

   Eligible transactions are accessible to the user who started the run, non-excluded, non-transfer, non-split-parent transactions with `category_id: nil` and `Transaction.enrichable(:category_id)`. This follows the quick-categorize surface while avoiding family-wide changes to accounts the current user cannot access. The query object should be equivalent to:

   ```ruby
   run.family
     .entries
     .joins(:account)
     .merge(Account.accessible_by(run.user))
     .excluding_split_parents
     .uncategorized_transactions
     .merge(Transaction.enrichable(:category_id))
   ```

   Run creation persists one `AutoCategorizationRunTransaction` per eligible transaction before any LLM call. Starter category generation and transaction suggestion generation use that immutable snapshot. Apply uses the snapshot for audit/display but rechecks the live transaction, entry, account access, category lock, and selected category before writing.

3. Define a starter-category LLM provider contract.

   Suggestion generation calls `Provider::Registry.default_llm_provider`, the same provider selection used by PDF import. Starting a new run requires a configured default LLM provider; without one, the categories page shows a configuration-required state and the start action does not create a run or enqueue a job.

   Add `Provider::LlmConcept::SuggestedCategory = Data.define(:name, :parent_name, :color, :lucide_icon, :rationale)` and `Provider::LlmConcept#suggest_categories(transactions:, model: "", family: nil, json_mode: nil)`, returning the existing `Provider::Response` wrapper. `Provider::Openai` implements it and `Provider::OpenaiViaCodex` inherits it.

   When the family has no categories, generation calls `suggest_categories` using the run transaction snapshot. Provider output is normalized before persistence: trim names, reject blank names, de-dupe case-insensitively against existing family categories and the same response, validate hex colors or assign from `Category::COLORS`, validate icons against `Category.icon_codes` or fall back to `Category.suggested_icon`, and allow only one parent level. Approved category suggestions are created as real `Category` records only after user review.

   Transaction suggestion generation uses `auto_categorize` only after at least one family category exists. The service builds the transaction/category input shape from the snapshot and persists one transaction suggestion row per snapshotted transaction, including no-match rows that the provider omits or returns with invalid category names.

4. Use import-style jobs with owned progress, retries, and chunking.

   `AutoCategorizationGenerateJob` creates either starter category suggestions or transaction suggestions and marks the run ready for the next review step. `AutoCategorizationCreateCategoriesJob` creates reviewed starter categories and queues transaction suggestion generation. `AutoCategorizationApplyJob` applies selected transaction suggestions after the user confirms.

   Jobs use app-owned retries instead of Sidekiq automatic retries. Each job claims the run with a `job_id`, writes guarded progress only when the stored `job_id` matches, and never lets an older job overwrite a newer retry's progress or persisted results. `processing_progress` stores `phase`, `message`, `current`, `total`, `percent`, `job_id`, `retry_count`, `started_at`, `last_updated_at`, and `finished_at`. The run should expose helpers equivalent to import processing: `update_processing_progress!`, `finish_processing_progress!`, `fail_processing_progress!`, `processing_progress_job_matches?`, `retryable_processing?`, `retryable_processing_stall?`, and `queue_retry!`.

   Use explicit constants such as `PROCESSING_PROGRESS_STALE_AFTER = 5.minutes`, `GENERATION_BATCH_SIZE = 25`, `MAX_GENERATION_RETRIES = 1`, and `MAX_APPLY_RETRIES = 1`. Transaction suggestion generation processes snapshot rows in chunks, updates progress after each chunk, and resumes retry from unfinished or failed generation rows for the current step. A recovery job should enqueue one retry for stale owned progress when retry caps allow it.

5. Treat applied suggestions as user-approved category locks.

   Applying a reviewed suggestion updates only the selected live transaction:

   ```ruby
   transaction.update!(category_id: selected_category.id)
   transaction.lock_attr!(:category_id)
   ```

   The apply path must not call `Entry.bulk_update!`, must not mark the whole entry as user-modified, and must not create a `DataEnrichment` with source `"ai"`. This makes the reviewed choice durable without causing future AI cache resets to undo it or changing provider-sync protection for unrelated entry fields.

   Apply is idempotent. Rows with `applied_at` are skipped, selected rows whose live transaction, account access, lock state, or selected category is stale are counted as skipped, and unselected rows are counted as unchanged. Duplicate apply submissions enqueue at most one job by guarding status transitions under lock.

6. Use an import-style wizard with scalable review tables.

   The wizard uses the existing `wizard` layout and a stepper similar to imports. Families with categories follow Start, Suggest, Review, Done. Families without categories follow Start, Suggest Categories, Review Categories, Suggest Transactions, Review Transactions, Done.

   Starter category review lets the user select, deselect, and edit suggested category names, parent names, icons, colors, and rationales. If AI returns no usable starter categories or the user deselects everything, transaction suggestion generation remains disabled until the user adds a valid category suggestion manually, chooses the default `Category.bootstrap!` set, retries starter generation, or cancels.

   Transaction review uses a paginated table with search, status, selected-state, and category filters. Review params include `q` or `search`, `status`, `selected`, `category_id`, `page`, and `per_page`; `per_page` is clamped through the app's safe pagination pattern. Pagination links, row updates, category overrides, polling refreshes, and apply navigation preserve the current filter and page state unless the user changes filters, which resets to page 1. Sticky bars show selected counts from the database across all pages, not just the current page.

7. Sanitize errors and report outcomes precisely.

   Persist only sanitized user-facing errors, capped to a short message such as 500 characters. Do not persist provider payloads, prompts, API keys, raw transaction descriptions, account names, file paths, stack traces, or model output snippets. Full exception details should be logged server-side with run id and job id only.

   Completion counts should distinguish applied, skipped, and unchanged rows. Applied means a selected row updated and locked the transaction. Skipped means a selected row could not be applied because it became stale or invalid. Unchanged means an unselected or no-suggestion row was intentionally left untouched.

## Risks / Trade-offs

- Missing provider -> The wizard shows an AI configuration-required state and does not create a run or enqueue jobs. If a provider disappears after a run has already entered generation, the job fails with a sanitized configuration error and retry remains blocked until a provider is configured.
- LLM proposes poor starter categories -> Category suggestions are not created until the user reviews them, and the user can deselect, edit, manually add categories, use default categories, or retry.
- Transactions change after run creation -> LLM calls use the durable snapshot, while apply rechecks live eligibility and skips stale rows.
- Category renamed or deleted after suggestion generation -> Suggestions keep display names for audit, nullable category FKs are nullified, and apply skips stale selected rows.
- Selected-count accuracy across pages -> Store `selected` on each suggestion and calculate counts from the database instead of the current page.
- Duplicate active runs -> Allow multiple historical runs but surface the latest active run from Categories; starting a new run snapshots current eligible rows.
- Large families -> Use snapshot rows, database pagination, indexed foreign keys/status fields, chunked provider calls, owned progress, and background jobs for generation and application.

## Migration Plan

Add the run, run transaction snapshot, starter category suggestion, and transaction suggestion tables in one migration. Deploying the migration is additive and does not affect existing categorization flows. If the feature must be rolled back, remove the route/page action and leave the additive tables unused until a later cleanup migration.
