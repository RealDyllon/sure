## ADDED Requirements

### Requirement: Gate category cleanup by complete feature readiness
The system SHALL only expose a category cleanup wizard when controller, routes, views, navigation, provider contract, background jobs, persistence, and focused tests are present together.

#### Scenario: Cleanup wizard is complete
- **WHEN** the category cleanup wizard code remains in the branch
- **THEN** the system provides reachable navigation from Settings > Categories, controller actions for start/show/review/apply/retry, rendered views for every run state, provider integration, background jobs, and tests covering the full flow

#### Scenario: Cleanup wizard is incomplete
- **WHEN** the category cleanup wizard is missing any required controller, view, test, navigation, route, provider, job, or persistence piece
- **THEN** the system removes the incomplete wizard from exposed routes, navigation, provider contracts, and application code until a complete implementation is ready

### Requirement: Use configured LLM provider for cleanup suggestions
The system SHALL use the configured default LLM provider to generate reviewable category cleanup suggestions only when AI is available.

#### Scenario: Provider is configured
- **WHEN** a user starts category cleanup with a configured default LLM provider
- **THEN** the system snapshots the family categories and requests cleanup suggestions from the provider using the standard provider response wrapper

#### Scenario: Provider is unavailable
- **WHEN** a user starts or retries category cleanup without a configured default LLM provider
- **THEN** the system rejects the request with an AI configuration-required state and does not create, retry, or enqueue cleanup work

#### Scenario: Provider fails
- **WHEN** the provider fails while generating cleanup suggestions
- **THEN** the system marks the cleanup run failed, stores a sanitized error message, and does not change categories

### Requirement: Review cleanup suggestions before applying
The system SHALL require user review before renaming, merging, reparenting, hiding, or deleting categories based on AI cleanup suggestions.

#### Scenario: Suggestions are ready
- **WHEN** cleanup suggestion generation completes
- **THEN** the system shows each suggestion with action, source category, target/new parent/new name where applicable, rationale, confidence, and selected state

#### Scenario: User edits review choices
- **WHEN** a user selects, deselects, or changes cleanup suggestions
- **THEN** the system persists those review choices before any category changes are applied

#### Scenario: Apply selected suggestions
- **WHEN** a user applies reviewed cleanup suggestions
- **THEN** the system applies only selected valid suggestions and reports applied, skipped, and unchanged counts

#### Scenario: Stale categories are skipped
- **WHEN** a selected category, target category, or parent category becomes unavailable before apply
- **THEN** the system skips that suggestion and reports the stale state without applying an invalid category change

### Requirement: Own cleanup async lifecycle and retry
The system SHALL own category cleanup job progress, retry, and idempotency so stale or duplicate jobs cannot apply category changes twice.

#### Scenario: Cleanup job claims run
- **WHEN** generation or apply work starts
- **THEN** the job claims the cleanup run with a job id and writes progress only while that job id remains current

#### Scenario: Older job continues after retry
- **WHEN** an older cleanup job continues after a newer retry has claimed the run
- **THEN** the older job does not update progress, persist suggestions, or apply category changes

#### Scenario: Failed cleanup can retry
- **WHEN** generation or apply fails or becomes stale and retry count is below the configured cap
- **THEN** the system allows a retry with a new job id while preserving reviewed data that has already been safely committed

#### Scenario: Duplicate apply is idempotent
- **WHEN** a user submits cleanup apply more than once
- **THEN** the system enqueues at most one active apply job and repeated jobs skip suggestions already applied or no longer valid

### Requirement: Sanitize cleanup errors and avoid sensitive data
The system SHALL store and display only sanitized cleanup errors and SHALL avoid persisting real personal financial details in cleanup prompts, examples, tests, fixtures, logs, or documentation.

#### Scenario: Cleanup provider error is persisted
- **WHEN** a cleanup provider call fails
- **THEN** the system stores a sanitized short error suitable for display on the cleanup run

#### Scenario: Sensitive details are omitted
- **WHEN** cleanup errors, tests, fixtures, docs, or logs are created
- **THEN** the system omits API keys, OAuth tokens, account names, account numbers, balances, transaction details, prompts, stack traces, and raw provider payloads
