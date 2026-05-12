## Why

AI features can fail silently or opaquely when the selected provider is unavailable, under-budgeted, mis-authenticated, or only configured in a different runtime than Sidekiq. The sidebar assistant, OpenAI/Codex settings, and partial category cleanup work need explicit health, realistic provider defaults, predictable retries, and a clear product stance before more AI surfaces depend on them.

## What Changes

- Make the assistant sidebar show explicit AI health: selected provider, effective model, auth/config status, effective context/output/item budgets, and the exact sanitized provider error when a request fails.
- Add a settings smoke-test action for OpenAI and Codex that runs through the same queued worker/runtime path used by Sidekiq-backed AI jobs and reports the result back to settings.
- Replace one-size-fits-all low LLM budget defaults with provider/model-aware defaults while keeping environment and local-model overrides.
- Harden chat creation, response generation, retry, and error recovery, including fixing the API retry path so it retries the last user turn instead of asking the assistant to respond to an empty assistant message.
- Add focused tests for chat create/respond/retry, Codex SSE parsing, provider-unavailable UI, and worker auth/config failures.
- Decide and document whether Codex is a first-class provider or an experimental self-hosting option, including ChatGPT account/session implications and the fact that Codex auth must be available to worker processes.
- Finish the category cleanup wizard so controller, views, tests, navigation, and provider contracts are present, or remove its routes/models/jobs/provider hooks from the branch until it is complete.
- No breaking changes to existing public APIs.

## Capabilities

### New Capabilities
- `ai-provider-reliability`: Provider health, settings smoke tests, budget normalization, Codex positioning/docs, and chat retry/error recovery for built-in AI.
- `ai-category-cleanup`: Category cleanup wizard readiness contract, including the requirement that incomplete cleanup wizard code is either finished end-to-end or removed from exposed app surfaces.

### Modified Capabilities

None.

## Impact

- Affects Rails models/controllers/jobs/views around chats, messages, assistant sidebar, self-hosting settings, provider registry, OpenAI/Codex providers, and category cleanup.
- Adds or adjusts Minitest coverage for chat controller/model/job flows, API retry behavior, Codex client SSE handling, settings smoke-test worker behavior, provider-unavailable UI, and category cleanup readiness.
- May add a small persisted or cache-backed smoke-test result record/state, or reuse existing settings/job patterns if they can provide durable worker-runtime feedback.
- Updates self-hosting documentation and settings copy for Codex account/session requirements and provider status.
- Does not add public API endpoints, so OpenAPI rswag artifacts are not required unless implementation later exposes a new `/api/v1` endpoint.
