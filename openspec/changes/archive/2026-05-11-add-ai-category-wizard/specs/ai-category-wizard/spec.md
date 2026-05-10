## ADDED Requirements

### Requirement: Launch AI category wizard from Categories settings
The system SHALL provide an AI auto-categorization wizard entry point from Settings > Categories when a default LLM provider is configured, whether or not the family already has categories.

#### Scenario: Launch is available with categories
- **WHEN** a user visits Settings > Categories with at least one category and a configured default LLM provider
- **THEN** the system shows an Auto-categorize action that starts the AI category wizard

#### Scenario: Launch starts category setup without categories
- **WHEN** a user visits Settings > Categories with no family categories and a configured default LLM provider
- **THEN** the system allows the wizard to start and uses eligible uncategorized transaction snapshots to generate starter category suggestions

#### Scenario: Launch is unavailable without provider
- **WHEN** a user visits Settings > Categories without a configured default LLM provider
- **THEN** the system explains that AI configuration is required and does not create a run, enqueue a job, or start suggestion generation

#### Scenario: Direct start is blocked without provider
- **WHEN** a user submits a direct start or retry request without a configured default LLM provider
- **THEN** the system returns the AI configuration-required state without creating or retrying a run

### Requirement: Generate suggestions only from eligible transaction snapshots
The system SHALL use only transactions accessible to the initiating user that are non-excluded, non-transfer, non-split-parent, uncategorized, and unlocked for `category_id` as input for starter category suggestions and transaction category suggestions.

#### Scenario: Eligible transactions are durably snapshotted
- **WHEN** a user starts the wizard
- **THEN** the system creates a run with one durable snapshot row per eligible transaction, including live nullable entry, transaction, and account references plus immutable prompt-input metadata

#### Scenario: Ineligible transactions are excluded
- **WHEN** transactions are transfers, excluded, split parents, already categorized, hidden by account status, in accounts not accessible to the initiating user, or locked for `category_id`
- **THEN** the system excludes those transactions from starter category and transaction category suggestion generation

#### Scenario: No eligible transactions
- **WHEN** the family has no eligible uncategorized transactions for the initiating user
- **THEN** the system shows an empty state and makes no LLM request

#### Scenario: Snapshot is stable after live edits
- **WHEN** a transaction is edited after the run snapshot is created
- **THEN** starter category and transaction suggestion generation use the original snapshot metadata for LLM input

### Requirement: Define starter-category LLM provider contract
The system SHALL define a starter-category LLM provider contract that can suggest categories before the family has categories.

#### Scenario: Provider implements starter category suggestions
- **WHEN** the configured provider supports AI categorization
- **THEN** it provides `suggest_categories` returning `Provider::LlmConcept::SuggestedCategory` records through the standard `Provider::Response` wrapper

#### Scenario: Provider output is normalized
- **WHEN** the provider returns starter category suggestions
- **THEN** the system trims names, rejects blank names, de-dupes duplicate names, validates or defaults colors and icons, prevents self-parenting, and allows only one parent level before persisting review rows

#### Scenario: Transaction generation waits for real categories
- **WHEN** the family has zero real categories
- **THEN** the system does not call transaction `auto_categorize` until at least one family category exists

### Requirement: Suggest starter categories when none exist
The system SHALL use the eligible transaction snapshot to request reviewable starter category suggestions when the family has no categories.

#### Scenario: Provider returns starter category suggestions
- **WHEN** the configured LLM provider returns starter category names from eligible transaction snapshot metadata
- **THEN** the system persists reviewable category suggestions with name, optional parent name, icon, color, rationale, and selected state

#### Scenario: User reviews starter categories
- **WHEN** starter category suggestions are ready
- **THEN** the system lets the user select, deselect, edit, and manually add category suggestions before creating any categories

#### Scenario: No usable starter suggestions
- **WHEN** the configured LLM provider returns no usable starter category suggestions
- **THEN** the system shows a starter-category empty state with retry, manual add, default category bootstrap, cancel, and back actions without queuing transaction suggestion generation

#### Scenario: No reviewed starter categories are selected
- **WHEN** the user has no valid selected starter category suggestions
- **THEN** the system disables category creation and transaction suggestion generation until a valid category is selected, manually added, or bootstrapped from defaults

#### Scenario: Approved starter categories are created
- **WHEN** the user confirms reviewed starter category suggestions
- **THEN** the system creates only approved categories and continues to transaction category suggestion generation using those categories

#### Scenario: Starter category provider fails
- **WHEN** the configured LLM provider fails while suggesting starter categories
- **THEN** the system marks the run failed, stores a sanitized error message, and does not create categories or change transactions

### Requirement: Use configured LLM provider for transaction suggestions
The system SHALL use `Provider::Registry.default_llm_provider` to request transaction category suggestions with available family categories and eligible transaction snapshot metadata.

#### Scenario: Provider returns valid transaction category suggestions
- **WHEN** the configured LLM provider returns category names that match family categories
- **THEN** the system persists suggestions linked to the matching category records and selected by default

#### Scenario: Provider omits a transaction or returns no category
- **WHEN** the configured LLM provider omits a snapshotted transaction, returns `null`, or returns no valid category for a transaction
- **THEN** the system still persists a row for that snapshot as needing review and leaves it unselected by default

#### Scenario: Provider fails during generation
- **WHEN** the configured LLM provider returns an error or raises during suggestion generation
- **THEN** the system marks the run failed, stores a sanitized error message, and does not change transaction categories

### Requirement: Review suggestions before applying
The system SHALL require user review before any AI-suggested starter category is created and before any suggested transaction category is committed to transactions.

#### Scenario: Transaction suggestions are shown in a scalable table
- **WHEN** suggestion generation completes
- **THEN** the system presents suggestions in a paginated and filterable table with transaction snapshot details, stale indicators, suggested category, selection state, and category override controls

#### Scenario: Valid suggestions are selected by default
- **WHEN** a suggestion has a valid matched category
- **THEN** the system marks that suggestion selected by default

#### Scenario: No-suggestion rows are unselected by default
- **WHEN** a suggestion has no valid matched category
- **THEN** the system leaves that suggestion unselected by default

#### Scenario: User changes selection across pages
- **WHEN** a user selects, deselects, or changes categories on suggestions across multiple pages
- **THEN** the system persists those review choices on the suggestion records and preserves current search, filter, page, and per-page state

#### Scenario: Review page size is bounded
- **WHEN** a user changes `per_page`
- **THEN** the system clamps it to the allowed safe pagination values and never renders more rows than the selected safe page size

### Requirement: Apply only reviewed selected suggestions
The system SHALL apply only selected suggestions with a user-selected category and SHALL skip stale or invalid rows at apply time.

#### Scenario: Selected suggestions are applied
- **WHEN** the user applies reviewed suggestions
- **THEN** the system updates only selected eligible transactions to the reviewed category

#### Scenario: Unselected suggestions are unchanged
- **WHEN** suggestions are unselected at apply time
- **THEN** the system leaves their transactions uncategorized and counts those rows as unchanged

#### Scenario: Stale suggestions are skipped
- **WHEN** a selected transaction, entry, accessible account, or selected category is no longer available or eligible
- **THEN** the system skips that suggestion and reports it in the run result

#### Scenario: Deleted selected category is skipped
- **WHEN** a selected category is deleted after review and before apply
- **THEN** the system nullifies the stale suggestion reference where applicable, skips the row, and preserves the category display name for reporting

#### Scenario: Applied categories are user-approved locks
- **WHEN** a selected suggestion is applied
- **THEN** the system updates the transaction category, locks only `category_id`, does not mark the entry user-modified, and does not create AI-owned enrichment data

### Requirement: Own async job lifecycle and retry
The system SHALL own wizard job progress, retry, and idempotency so stale or duplicate jobs cannot create categories or apply transactions twice.

#### Scenario: Jobs claim the run
- **WHEN** generation, category creation, retry, or apply work starts
- **THEN** the job claims the run with a job id and writes progress only while that job id remains current

#### Scenario: Stale jobs cannot overwrite newer retries
- **WHEN** an older job continues after a newer retry has claimed the run
- **THEN** the older job does not update progress, create categories, persist suggestions, or apply transactions

#### Scenario: Failed or stale work can be retried within caps
- **WHEN** generation or apply fails or becomes stale and retry count is below the configured cap
- **THEN** the system allows a retry with a new job id and preserves reviewed data that has already been safely committed

#### Scenario: Duplicate submissions are idempotent
- **WHEN** a user submits category creation or apply more than once
- **THEN** the system enqueues at most one active job and repeated jobs skip rows that were already created or applied

### Requirement: Report chunked progress and outcomes
The system SHALL show generation, review, apply, completion, failure, retry, and chunked progress states for each AI categorization run.

#### Scenario: Generation is in progress
- **WHEN** suggestion generation is queued or running
- **THEN** the wizard shows a processing state that can refresh until the run is ready, failed, or empty

#### Scenario: Large generation reports progress
- **WHEN** the run has 100 or more eligible transaction snapshots
- **THEN** transaction suggestion generation processes chunks and reports current count, total count, and percent complete

#### Scenario: Category setup is in progress
- **WHEN** the family has no categories and starter category suggestions are being generated, reviewed, or created
- **THEN** the wizard shows the category setup step before transaction suggestion review

#### Scenario: Apply is in progress
- **WHEN** selected suggestions are being applied
- **THEN** the wizard shows an applying state and prevents duplicate apply submissions

#### Scenario: Run completes
- **WHEN** apply finishes
- **THEN** the wizard shows applied, skipped, and unchanged counts and links back to Settings > Categories

#### Scenario: Run can be retried after failure
- **WHEN** suggestion generation fails
- **THEN** the wizard provides a retry action that reruns the failed starter category or transaction category generation step without creating categories or applying transaction categories first

### Requirement: Sanitize persisted errors
The system SHALL store and display only sanitized user-facing errors for AI category wizard runs.

#### Scenario: Provider error is persisted
- **WHEN** a provider call fails
- **THEN** the run stores a sanitized error message capped to a short user-facing length

#### Scenario: Sensitive details are omitted
- **WHEN** an error is sanitized
- **THEN** the persisted error omits provider payloads, prompts, API keys, raw transaction descriptions, account names, file paths, stack traces, and raw model output snippets
