## Context

The app currently selects one built-in LLM provider through `Setting.effective_llm_provider` and `Provider::Registry.default_llm_provider`. OpenAI uses API-key based configuration and supports native Responses API or OpenAI-compatible chat calls. Codex is wired as `Provider::OpenaiViaCodex`, reads ChatGPT/Codex CLI auth, and adapts Codex SSE responses into the existing OpenAI-shaped provider contract.

The sidebar chat path creates a `UserMessage`, enqueues `AssistantResponseJob`, streams output into an `AssistantMessage`, and stores classified errors on `Chat#error`. Settings expose provider, model, JSON mode, and global LLM budgets, but the runtime health shown to users is implicit. The current API retry endpoint creates an empty `AssistantMessage` and enqueues it directly, so the job calls `request_response` on the wrong message type instead of retrying the preceding user turn.

There is also partial category cleanup wizard code in the branch. It must not remain half-exposed: routes, controller, views, provider contract, navigation, and tests need to exist together, or the feature should be removed from app surfaces until it can be completed.

## Goals / Non-Goals

**Goals:**

- Make provider health visible where users see chat failures and where admins configure AI.
- Run provider smoke tests in the same queued worker/runtime path used by Sidekiq jobs.
- Resolve LLM budgets from provider/model defaults first, then allow environment/settings overrides.
- Make chat create/respond/retry paths consistent between web and API.
- Preserve exact technical provider errors for admins/debugging while showing sanitized user-facing copy.
- Treat Codex as an experimental self-hosting provider with clear local-session and worker-runtime requirements.
- Ensure the category cleanup wizard is either complete enough to navigate and test, or absent from routes/navigation/provider hooks.

**Non-Goals:**

- Do not add a new public API endpoint unless implementation proves the existing API retry endpoint cannot be fixed in place.
- Do not store raw prompts, transaction data, account names, API keys, OAuth tokens, Codex auth files, or provider payloads in smoke-test results or chat errors.
- Do not make Codex the default provider for hosted or production installs.
- Do not redesign all AI settings; keep this focused on reliability, visibility, and readiness.

## Decisions

1. Add a provider health/status object instead of scattering checks in views.

   Create a small service or value object such as `Provider::LlmHealth` that resolves the selected provider key, provider instance presence, effective model, auth/config status, budget values, budget sources, and the last exact sanitized provider error when one is available. Views should render this object in the sidebar and self-hosting settings. The alternative was to inline `Provider::Registry` checks in views, but that would duplicate provider selection and make tests brittle.

2. Store exact provider errors as sanitized technical strings, not raw payloads.

   Keep the current two-level behavior: a user-facing classified error plus an exact technical message for admin/debug surfaces. The exact message must strip secrets, raw prompt content, account/file paths, stack traces, and large response bodies before persistence. The alternative was to show only generic messages, but that leaves users unable to fix misconfigured provider/model/auth failures.

3. Run smoke tests through a queued job and a durable result.

   Add an admin-only settings action that enqueues a smoke-test job for the selected provider/model and records status as queued/running/succeeded/failed with timestamps, effective provider/model/budgets, and sanitized error. The job must run normal provider construction and a minimal provider call inside the worker runtime. The controller should not directly call the provider because that only proves the web process is configured.

4. Centralize provider/model budget resolution.

   Introduce a resolver used by OpenAI, Codex, and settings health display. Resolution order should be `ENV` override, persisted setting override, provider/model default, then conservative fallback. OpenAI cloud defaults should match realistic current OpenAI models, Codex defaults should match known Codex model windows, and custom/local OpenAI-compatible providers should keep conservative defaults unless the admin sets overrides. The alternative was to raise the global defaults, but that can break local providers that still need small contexts.

5. Make chat retry target the last user turn.

   Web and API retries should call the same model-level behavior: clear chat error, find the last complete user message that can be retried, create a fresh pending assistant message, and enqueue `AssistantResponseJob` with both the user message and pending assistant message. Retrying must not include failed or partial assistant messages in history. The alternative was to keep separate web/API retry implementations, which already diverged and introduced the API retry bug.

6. Treat Codex as experimental self-hosting, not first-class production OpenAI.

   Codex remains selectable when configured, but settings and docs must say it uses a ChatGPT/Codex CLI session, is intended for self-hosters, can fail when Sidekiq lacks the same home/auth environment, and may have account/session implications different from an OpenAI API key. The alternative was to present Codex as equivalent to OpenAI, but its auth and API stability are materially different.

7. Gate category cleanup by readiness.

   The implementation must either finish the category cleanup wizard end-to-end or remove it from routes/navigation/provider contracts and uncommitted app code. If finished, it needs the same provider availability, retry/idempotency, review-before-apply, and tests expected of other AI category workflows. The alternative was to leave partial code hidden, but routes/provider hooks without complete UI and tests create maintenance risk.

## Risks / Trade-offs

- Smoke-test jobs may fail because the worker has a different environment than web -> Surface that distinction explicitly in result details and docs.
- Exact provider errors can leak sensitive data -> Sanitize before persistence and cap displayed length.
- Larger cloud defaults may increase token spend -> Keep max-items slicing and make budgets visible/editable.
- Codex model metadata can change -> Use provider defaults plus graceful fallback and document experimental status.
- A queued smoke test adds state to settings -> Keep the result minimal and expire/cache old results if a table is unnecessary.
- Removing partial category cleanup code may discard work -> Prefer finishing only if the missing controller/views/tests/navigation can be completed within the implementation branch.

## Migration Plan

This change can be additive. Add new service objects, optional smoke-test state, routes/actions, views, copy, and tests. If a durable smoke-test table is added, make it additive and scoped to settings/admin use. Existing chat records and provider settings continue to work; error payload parsing must remain backwards-compatible with legacy string errors.

Rollback can remove smoke-test routes/views/jobs and fall back to existing provider settings. Budget resolver changes should preserve environment and persisted setting overrides so rollback does not require data migration.

## Open Questions

- Whether smoke-test result state should be a database record, Rails cache entry, or Setting-backed JSON depends on existing settings conventions during implementation.
- Category cleanup should be finished only if the current partial branch is close enough after audit; otherwise remove it from exposed app surfaces and leave a follow-up OpenSpec for a complete wizard.
