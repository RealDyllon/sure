# Upstream rebuild

This fork is based on `we-promise/sure` **v0.7.5-hotfix.1**, commit
`789883081feda49fcfa8c7bc923cc77c9fe301ad`. Keep upstream's release version; fork additions are separate commits.

## Preserved history

- `codex/legacy-2026-10-03` and `legacy/pre-upstream-rebuild-2026-10-03` preserve the former local checkout, including unfinished diagnostics.
- `codex/legacy-remote-main-2026-10-03` preserves the previous origin main.
- `codex/rebuild-on-upstream-0.7.5` contains the reviewed rebuild.

All archives belong to origin (`RealDyllon/sure`). Only publish branches or PRs to origin.

## Retained features

- Optional OpenAI via Codex login, selected explicitly using `LLM_PROVIDER=codex` or hosting settings. OpenAI and Anthropic remain upstream defaults. No fallback when Codex is selected but login is missing.
- DBS consolidated PDF and DBS/UOB/PayLah/CPF/IBKR statement parsing, account review, remembered account matches, background extraction and progress, password-protected PDFs, transactions, investment trades, and closing-balance valuations.
- Original statement files live in upstream's statement vault. Exact duplicate uploads reuse the existing import. Statement imports are private to their initiating user. Publication checks account permissions again.
- Existing entries are reconciled rather than overwritten. Repeated identical transactions retain separate occurrences. Publishing is atomic and repeat-safe. Reversal restores reconciliation marks, prior balance valuations and remembered mappings. Reversal refuses to delete accounts with later independent activity or provider links.
- Positions are informational; they are not imported as holdings. Review extracted values before publishing.
- FIRE under **Plan → FIRE planning** for users with Preview features enabled. Accessible bridge assets and later retirement assets are separate, with CPF/SRS roles and editable access-age assumptions. Preview validates without saving; saved settings are private to each user. Hidden and inaccessible accounts are excluded.

Upstream Wise syncing, transaction rules, Quick Categorize and category merging replace the former custom categorization and cleanup wizards. The old financial-goals dashboard and its emergency-fund, debt and savings calculators are not restored. FX planning remains deferred.

## Ruby and dependencies

Use **mise** for Ruby:

```sh
mise install ruby@3.4.9
mise exec ruby@3.4.9 -- bundle install
npm ci
npm run tokens:build
mise exec ruby@3.4.9 -- bin/rails tailwindcss:build
```

PostgreSQL, Redis and libvips must be available. On this Mac, PostgreSQL 18 comes from Postgres.app; Redis and libvips were installed with Homebrew.

## Local isolated environment

The rebuild uses new databases, new encryption keys and new upload storage. Old databases, uploads and configuration are preserved outside the running configuration. Do not point this checkout at the legacy database: migration histories differ.

Local services:

- PostgreSQL: `localhost:55432`, cluster `.local/postgres-rebuild`.
- Redis: `127.0.0.1:56379`, development database 2, test database 3.
- Development database: `sure_rebuild_development`.
- Test database: `sure_rebuild_test` (parallel test databases are disposable).
- Uploads: `.local/sure-rebuild/storage` through `LOCAL_STORAGE_ROOT`.
- App: `http://localhost:3000`.

Private `.env.local` and `.env.test.local` contain the local configuration. Former root `.env*` files are archived privately under `.local/legacy-config/2026-10-03/`; never commit that directory. Test configuration must use `SELF_HOSTED=false`, upstream test encryption keys, and no forced LLM provider or blank API-token overrides; provider tests control their own environment.

```sh
mise exec ruby@3.4.9 -- bin/rails db:prepare
RAILS_ENV=test mise exec ruby@3.4.9 -- bin/rails db:prepare
mise exec ruby@3.4.9 -- bin/dev
```

If the CSS process exits immediately and Foreman stops the group, run the server, Sidekiq and Tailwind watcher separately. `bin/local-services` starts the isolated PostgreSQL and Redis services after a reboot.

## Codex

Run `codex login` as the user running Rails and Sidekiq. The provider reads `~/.codex/auth.json`, or `CODEX_AUTH_PATH`. It refreshes expiring tokens under a process mutex and file lock, and atomically replaces the private auth file. Do not copy tokens into settings or Git.

For local Codex selection:

```dotenv
LLM_PROVIDER=codex
OPENAI_MODEL=openai-codex/gpt-6.1-sol
```

Set a model available to your Codex login. Model discovery uses the Codex endpoint; the retained fallback list is used if discovery fails. Codex requests use the Responses streaming endpoint with full message history, tool results and `store: false`. OpenAI embeddings and vector-store credentials are configured separately; Codex login does not provide embeddings.

## Verification and updates

```sh
RAILS_ENV=test PARALLEL_WORKERS=4 mise exec ruby@3.4.9 -- bin/rails test
mise exec ruby@3.4.9 -- bin/rubocop
mise exec ruby@3.4.9 -- bundle exec erb_lint --lint-all
npm run lint
mise exec ruby@3.4.9 -- bin/brakeman
```

Verified on this Mac: multi-account CSV review and publication, FIRE preview/save/validation, Codex chat and function calling, and synthetic PDF text/image probes. Final validation: **10,395 tests, 43,763 assertions, 0 failures, 0 errors, 33 upstream skips**; changed Ruby files and all ERB templates pass lint, Biome passes, and Brakeman reports zero warnings or errors. One upstream holding-import test now chooses a date before its fixture holdings so system/Rails time-zone differences cannot collide.

Use only synthetic statement contents and financial data in tests, screenshots and diagnostics. Never print auth files or environment values.

For future updates, fetch upstream, select a stable tag, and merge or rebase the small fork additions. Keep generic provider, statement-vault and Plan behavior close to upstream. Verify the full test suite and retained workflows before moving main. Legacy history is for selective reference, not a bulk merge.
