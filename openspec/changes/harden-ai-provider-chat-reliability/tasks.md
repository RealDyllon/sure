## 1. Audit And Test Baseline

- [ ] 1.1 Audit current uncommitted AI provider, chat retry, Codex, settings, and category cleanup changes against this OpenSpec and decide whether category cleanup will be finished or removed in this implementation branch.
- [ ] 1.2 Add focused failing tests for web chat create/respond/retry behavior, including no duplicate assistant jobs and clearing stale chat errors on retry.
- [ ] 1.3 Add focused failing tests for API message create/retry behavior that prove API retry uses the last retryable user message and never enqueues `AssistantResponseJob` with an assistant message as the prompt.
- [ ] 1.4 Add focused failing tests for provider-unavailable sidebar/settings UI and worker-runtime auth/config failure reporting.
- [ ] 1.5 Add or extend Codex client tests for SSE output deltas, refusal deltas, function calls, unsuccessful HTTP responses, invalid JSON, and streams that finish without a completed response.

## 2. Provider Health And Error Visibility

- [ ] 2.1 Implement a central LLM health/status object that resolves selected provider key, provider availability, effective model, auth/config status, effective budgets, budget sources, and sanitized last error.
- [ ] 2.2 Update chat error persistence to retain a classified user-facing error plus a sanitized exact technical provider error while remaining compatible with legacy string error payloads.
- [ ] 2.3 Render provider health in the assistant sidebar, including provider unavailable state, effective model, auth/config status, budgets, and exact sanitized provider error for failed chats.
- [ ] 2.4 Render provider health in self-hosting AI settings and mark environment-backed provider/model/budget fields as overridden or non-editable.
- [ ] 2.5 Add tests proving provider health omits API keys, OAuth tokens, prompts, account names, raw financial data, stack traces, and oversized provider payloads.

## 3. Worker Runtime Smoke Test

- [ ] 3.1 Add an admin-only self-hosting settings route/action to enqueue a built-in AI provider smoke test without performing provider calls in the web request.
- [ ] 3.2 Implement smoke-test result state using the smallest durable/cache-backed structure that can report queued, running, succeeded, failed, timestamps, provider, model, budgets, and sanitized error.
- [ ] 3.3 Implement a smoke-test job that constructs the selected OpenAI or Codex provider and runs a minimal request in the same worker runtime used by Sidekiq jobs.
- [ ] 3.4 Render smoke-test controls and latest result in self-hosting AI settings, including worker-runtime failure copy.
- [ ] 3.5 Add controller/job tests for admin authorization, enqueue behavior, success result recording, provider unavailable failure, and Codex worker auth failure.

## 4. Budget Resolution And Codex Positioning

- [ ] 4.1 Implement a shared provider/model budget resolver with precedence `ENV` override, persisted setting override, provider/model default, conservative fallback.
- [ ] 4.2 Wire OpenAI cloud models to realistic provider/model defaults while keeping custom OpenAI-compatible providers on conservative defaults unless overridden.
- [ ] 4.3 Wire Codex models to Codex context/output defaults and expose those values through provider health.
- [ ] 4.4 Update settings placeholders/help text so displayed budget defaults match the selected provider/model instead of hard-coded legacy values.
- [ ] 4.5 Document Codex as an experimental self-hosting provider, including ChatGPT/Codex CLI auth, account/session implications, and worker-runtime environment requirements.
- [ ] 4.6 Add model/service tests for budget precedence, provider/model defaults, custom provider conservative fallback, invalid override fallback, and settings display values.

## 5. Chat Retry And Recovery

- [ ] 5.1 Refactor chat retry into one model-level path used by both web and API controllers.
- [ ] 5.2 Fix API retry so it retries the last retryable user message, creates one pending assistant message, and enqueues one `AssistantResponseJob` with the user message plus pending assistant message.
- [ ] 5.3 Ensure failed or partially streamed assistant messages are marked/excluded so subsequent provider conversation history only includes complete messages.
- [ ] 5.4 Ensure chat create/respond paths for web and API rely on one enqueue mechanism and do not duplicate assistant responses.
- [ ] 5.5 Add or update tests for retry with no retryable user message, retry after provider failure, retry after partial stream failure, and retry authorization/scope failures.

## 6. Category Cleanup Readiness

- [ ] 6.1 If finishing category cleanup, complete routes, controller actions, navigation from Settings > Categories, views for every run state, provider method, jobs, persistence, and review/apply/retry flow.
- [ ] 6.2 If removing category cleanup, remove cleanup routes, navigation, models, jobs, provider hooks, views, migrations, and tests from the implementation branch until a complete wizard is built.
- [ ] 6.3 If finishing category cleanup, add tests for provider-required start/retry, generation failure, review selection persistence, apply selected suggestions, stale category skip, retry idempotency, and sanitized errors.
- [ ] 6.4 If finishing category cleanup, ensure prompts/tests/fixtures/docs use only synthetic category names and never include real account names, balances, transaction details, API keys, provider payloads, or prompts.

## 7. Verification

- [ ] 7.1 Run targeted chat, message, assistant, provider health, smoke-test, Codex client, and category cleanup tests.
- [ ] 7.2 Run `bin/rails test` or the narrowest reliable Rails test subset covering changed app areas.
- [ ] 7.3 Run `bin/rubocop` and fix offenses in changed Ruby files.
- [ ] 7.4 Run `openspec validate harden-ai-provider-chat-reliability --strict` and fix any proposal/spec/task issues.
- [ ] 7.5 Confirm no `spec/requests/api/v1/` rswag changes are required unless a new public API endpoint was added.
