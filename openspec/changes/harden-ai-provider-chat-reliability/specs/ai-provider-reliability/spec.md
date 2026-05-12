## ADDED Requirements

### Requirement: Expose built-in AI provider health
The system SHALL expose built-in AI provider health in the assistant sidebar and self-hosting AI settings, including selected provider, effective model, auth/config status, effective context window, effective max response tokens, effective max items per call, and budget sources.

#### Scenario: Provider is configured
- **WHEN** a user opens the assistant sidebar or an admin opens self-hosting AI settings with a configured built-in AI provider
- **THEN** the system shows the selected provider, effective model, configured/authenticated status, and effective LLM budgets used by new requests

#### Scenario: Provider is unavailable
- **WHEN** no selected built-in AI provider can be constructed
- **THEN** the system shows a provider-unavailable state with the selected provider key, missing auth/config reason, and a settings link for users allowed to configure AI

#### Scenario: Environment overrides settings
- **WHEN** provider, model, auth, or budget values are supplied by environment variables
- **THEN** the system shows the environment-backed values as effective and marks the corresponding settings fields as non-editable or overridden

### Requirement: Preserve exact sanitized provider errors
The system SHALL store and display a sanitized exact provider error alongside the classified user-facing chat error.

#### Scenario: Provider request fails
- **WHEN** a built-in AI provider returns an error or raises during chat response generation
- **THEN** the system persists a user-facing classified error and a sanitized technical provider error for the failed chat

#### Scenario: Sidebar renders a failed chat
- **WHEN** a user opens a chat with a stored provider error
- **THEN** the sidebar shows the classified error and the exact sanitized provider error without exposing API keys, OAuth tokens, prompts, account names, raw financial data, stack traces, or large provider payloads

#### Scenario: Retry clears stale error
- **WHEN** a user retries a failed chat turn
- **THEN** the system clears the previous chat error before queuing the replacement assistant response

### Requirement: Run provider smoke tests in the worker runtime
The system SHALL provide an admin-only OpenAI/Codex smoke-test action from self-hosting AI settings that executes in the same queued worker runtime used by Sidekiq-backed AI jobs.

#### Scenario: Admin starts smoke test
- **WHEN** an admin starts a smoke test from self-hosting AI settings
- **THEN** the system enqueues a smoke-test job and records the test as queued or running with selected provider, effective model, and effective budgets

#### Scenario: Smoke test succeeds
- **WHEN** the worker constructs the selected provider and completes the minimal AI request
- **THEN** the system records success with completion time, provider, model, and sanitized diagnostic metadata

#### Scenario: Smoke test fails in worker
- **WHEN** the worker cannot construct the selected provider, authenticate, reach the provider, or receive a valid response
- **THEN** the system records failure with a sanitized exact error and indicates that the failure happened in the worker runtime

#### Scenario: Non-admin cannot start smoke test
- **WHEN** a non-admin user attempts to start a provider smoke test
- **THEN** the system rejects the request without enqueueing a job

### Requirement: Resolve budgets per provider and model
The system SHALL resolve context, output, and batching budgets per provider/model using provider-aware defaults while preserving explicit environment and settings overrides.

#### Scenario: Cloud OpenAI uses realistic defaults
- **WHEN** OpenAI is selected without explicit budget overrides and the configured model is a cloud OpenAI model
- **THEN** the system uses provider/model defaults that are suitable for that model instead of the legacy local-model-safe 2048/512 defaults

#### Scenario: Codex uses Codex defaults
- **WHEN** Codex is selected without explicit budget overrides
- **THEN** the system uses Codex model defaults for context and max output budgets and displays those defaults in provider health

#### Scenario: Custom local provider keeps conservative defaults
- **WHEN** an OpenAI-compatible custom URI is configured without explicit budget overrides
- **THEN** the system uses conservative local-provider defaults unless the admin sets larger environment or persisted budget values

#### Scenario: Explicit overrides win
- **WHEN** an environment variable or persisted setting supplies a valid budget value
- **THEN** the system uses that override ahead of provider/model defaults and shows the override source in provider health

### Requirement: Harden chat create, respond, and retry
The system SHALL make web and API chat create/respond/retry paths share the same retry semantics and error recovery behavior.

#### Scenario: Web chat message is created
- **WHEN** a user sends a web chat message with AI enabled
- **THEN** the system creates one user message, creates or queues one pending assistant response, and does not enqueue duplicate assistant jobs

#### Scenario: API chat message is created
- **WHEN** an API client creates a chat message with write scope and AI enabled
- **THEN** the system creates one user message, relies on the same response enqueue path as web chat, and does not enqueue duplicate assistant jobs

#### Scenario: Web retry retries user turn
- **WHEN** a user retries a failed or incomplete assistant response from the web UI
- **THEN** the system retries the last retryable user message by creating a fresh pending assistant message and enqueueing one response job for that user message

#### Scenario: API retry retries user turn
- **WHEN** an API client retries the last assistant response
- **THEN** the system uses the same retry behavior as web chat and does not enqueue a response job with an assistant message as the prompt message

#### Scenario: Failed assistant history is excluded
- **WHEN** a previous assistant response failed or only partially streamed before failure
- **THEN** the system excludes that failed assistant message from subsequent provider conversation history

### Requirement: Document Codex as experimental self-hosting
The system SHALL present Codex as an experimental self-hosting provider and document its account/session requirements clearly.

#### Scenario: Codex is selected in settings
- **WHEN** an admin selects Codex as the built-in AI provider
- **THEN** settings explain that Codex uses ChatGPT/Codex CLI auth, is intended for self-hosting, and requires the worker runtime to access the same auth/session environment

#### Scenario: Codex auth is missing from worker
- **WHEN** Codex auth is available to the web process but unavailable to the worker process
- **THEN** the smoke test and provider health show a worker-runtime auth failure instead of implying OpenAI API key configuration is missing

#### Scenario: Docs describe account implications
- **WHEN** a self-hoster reads AI provider documentation
- **THEN** the documentation explains Codex account/session implications, expected auth location/configuration, and the difference between OpenAI API-key auth and Codex ChatGPT-session auth

### Requirement: Parse Codex SSE responses reliably
The system SHALL parse Codex SSE responses into the built-in LLM response contract for normal text, refusals, function calls, completion events, and malformed streams.

#### Scenario: Codex streams output deltas
- **WHEN** Codex returns SSE output text or refusal deltas followed by a completion event
- **THEN** the system emits the completed assistant content through the standard LLM response shape

#### Scenario: Codex streams function calls
- **WHEN** Codex returns function call output in its response stream
- **THEN** the system converts each function call to the standard chat tool-call shape used by `Assistant::Responder`

#### Scenario: Codex stream is malformed
- **WHEN** Codex returns invalid JSON, an unsuccessful HTTP response, or a stream that completes without a response
- **THEN** the system returns a provider failure with a sanitized exact error suitable for chat health and smoke-test results
