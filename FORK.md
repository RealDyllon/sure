# Fork Comparison

Generated on 2026-06-04 from `/Users/dyllon/.codex/worktrees/c08d/sure`.

## Scope

This report compares the checked-out fork state with the closest corresponding ancestor on `upstream/main`.

- Current checkout: `fdbeaebd590fa1ee05778f3195e113f47534313d` (`Add OpenSpec for AI provider reliability`)
- Local state: detached `HEAD`, also matching local `main`
- Origin fork: `origin` = `git@github.com:RealDyllon/sure.git`
- Requested upstream: `upstream` = `git@github.com:we-promise/sure.git`
- `upstream/main` after fetch: `6a89efb9c9f79a5148965cb263e5a37ffa8afcc9` (`fix(goals): default goal currency so it survives a failed create (#2171)`)

## Relationship To `maybe-finance/maybe`

GitHub reports `RealDyllon/sure:main` as 2,579 commits ahead of and 1,419 commits behind `maybe-finance/maybe:main`. The local repo reproduces that exact count when comparing the pushed fork branch to the `maybe-finance` remote:

```sh
git rev-list --left-right --count maybe-finance/main...origin/main
# 1419 2579
```

This checkout has one additional local commit on top of `origin/main`, so comparing `HEAD` instead shows:

```sh
git rev-list --left-right --count maybe-finance/main...HEAD
# 1419 2580
```

That GitHub banner does not imply Git can find a merge base. Locally, `git merge-base --all origin/main maybe-finance/main` also returns no commit. Instead, the `maybe-finance` history appears rewritten in this fork: the 1,419 `maybe-finance/main` commits match by timestamp and subject, but the hashes differ. The latest logical match is:

- Fork-side equivalent: `498c58205b0c2998e3cc3da9c23a400fe9995c11`
- `maybe-finance/main` equivalent: `77b5469832758d1cbee1a940f3012a1ae1c74cd3`
- Shared subject: `Add attribution note`

This report still uses `upstream/main` (`we-promise/sure`) because that was the requested comparison target and is the configured `upstream` remote in this worktree.

## Ancestor Note

Git does not find a hash-identical merge base between this checkout and `upstream/main`:

```sh
git merge-base --all HEAD upstream/main
```

That command exits with status `1`. The repository is not shallow, so this appears to be a rewritten-history situation rather than missing local history. The roots differ even though they have the same initial commit message/date:

- Fork root: `802546fe 2024-02-02 09:05:04 -0600 Initial commit`
- Upstream root: `99de24ac 2024-02-02 09:05:04 -0600 Initial commit`

There is, however, a latest logical match by commit timestamp and subject:

- Fork-side equivalent ancestor: `5280aaef2f25b9fcaeeac3fc49939acbd0b47799`
- Upstream-side equivalent ancestor: `b74014ab4246403fdec09aeccb220b2b7eca21db`
- Shared subject: `Reject revoked OAuth tokens in API auth (#1711)`
- Shared commit timestamp: `1778283550`

The primary comparison below uses the fork-side equivalent ancestor:

```sh
git diff 5280aaef2f25b9fcaeeac3fc49939acbd0b47799..HEAD
```

If you specifically need the upstream-side object, use:

```sh
git diff b74014ab4246403fdec09aeccb220b2b7eca21db..HEAD
```

That upstream-side diff is slightly noisier because the equivalent ancestor trees are not byte-identical.

## Overall Diff Size

From the fork-side equivalent ancestor to `HEAD`:

- 184 changed paths
- 11,481 insertions
- 127 deletions
- Status counts: 94 modified, 90 added, 0 deleted

Top-level path distribution:

| Area | Paths | Modified | Added | Deleted |
| --- | ---: | ---: | ---: | ---: |
| `app/` | 79 | 42 | 37 | 0 |
| `test/` | 40 | 17 | 23 | 0 |
| `config/` | 25 | 25 | 0 | 0 |
| `openspec/` | 17 | 0 | 17 | 0 |
| `.superpowers/` | 8 | 0 | 8 | 0 |
| `db/` | 5 | 1 | 4 | 0 |
| other root files | 10 | 10 | 0 | 0 |

## Fork Changes Since The Equivalent Ancestor

### AI Transaction Categorization Wizard

The fork adds a user-facing AI category wizard at `/ai-category-wizard`:

- `app/controllers/auto_categorization_runs_controller.rb`
- `app/views/auto_categorization_runs/show.html.erb`
- `app/models/auto_categorization_run.rb`
- `app/models/auto_categorization_run_transaction.rb`
- `app/models/auto_categorization_suggestion.rb`
- `app/models/auto_categorization_category_suggestion.rb`
- `app/models/auto_categorization/apply_suggestions.rb`
- `app/models/auto_categorization/create_categories.rb`
- `app/models/auto_categorization/eligibility_query.rb`
- `app/models/auto_categorization/error_sanitizer.rb`
- `app/models/auto_categorization/generate_suggestions.rb`
- `app/models/auto_categorization/run_creator.rb`
- `app/models/auto_categorization/starter_category_normalizer.rb`
- `app/jobs/auto_categorization_apply_job.rb`
- `app/jobs/auto_categorization_create_categories_job.rb`
- `app/jobs/auto_categorization_generate_job.rb`
- `app/jobs/recover_stalled_auto_categorization_runs_job.rb`

It modifies existing categorization surfaces:

- `app/controllers/categories_controller.rb`
- `app/views/categories/index.html.erb`
- `app/models/family/auto_categorizer.rb`
- `app/models/rule/action_executor/auto_categorize.rb`
- `app/models/rule/registry/transaction_resource.rb`

### OpenAI And Codex-Backed LLM Provider Work

The fork adds a Codex-backed provider and expands OpenAI usage:

- `app/models/provider/openai/category_suggester.rb`
- `app/models/provider/openai_via_codex.rb`
- `app/models/provider/openai_via_codex/auth.rb`
- `app/models/provider/openai_via_codex/client.rb`
- `app/models/provider/registry.rb`
- `app/models/provider/openai.rb`
- `app/models/provider/openai/bank_statement_extractor.rb`
- `app/models/provider/llm_concept.rb`
- `app/models/llm_usage.rb`
- `app/models/chat.rb`

Related settings and docs changed:

- `app/views/settings/ai_prompts/show.html.erb`
- `app/views/settings/hostings/_openai_settings.html.erb`
- `app/controllers/settings/hostings_controller.rb`
- `config/locales/views/settings/hostings/en.yml`
- `docs/hosting/ai.md`
- `compose.example.ai.yml`
- `compose.example.yml`

### Statement Import Pipeline

The fork adds a statement import workflow for PDFs and CSVs:

- `app/models/statement_import.rb`
- `app/models/statement_profile.rb`
- `app/models/statement_extraction/csv_extractor.rb`
- `app/models/statement_extraction/extractor.rb`
- `app/models/statement_extraction/pdf_extractor.rb`
- `app/models/statement_extraction/profile_matcher.rb`
- `app/models/statement_extraction/publisher.rb`
- `app/models/statement_extraction/result.rb`
- `app/jobs/process_statement_import_job.rb`
- `app/jobs/recover_stalled_statement_imports_job.rb`
- `app/jobs/statement_import_enrichment_job.rb`
- `app/javascript/controllers/statement_review_controller.js`
- `app/javascript/controllers/statement_review_form_controller.js`
- `app/views/imports/_processing_progress.html.erb`
- `app/views/imports/_statement_import.html.erb`
- `app/javascript/controllers/page_polling_controller.js`

It also modifies existing import and PDF processing behavior:

- `app/controllers/imports_controller.rb`
- `app/controllers/import/cleans_controller.rb`
- `app/models/import.rb`
- `app/models/pdf_import.rb`
- `app/models/assistant/function/import_bank_statement.rb`
- `app/jobs/process_pdf_job.rb`
- `app/views/imports/_importing.html.erb`
- `app/views/imports/_pdf_import.html.erb`
- `app/views/imports/index.html.erb`
- `app/views/imports/new.html.erb`
- `app/views/imports/show.html.erb`
- `app/javascript/controllers/drag_and_drop_import_controller.js`

### Singapore And Reporting Adjustments

The fork adds Singapore-aware account/import/report behavior:

- `app/models/investment.rb`
- `app/models/account.rb`
- `app/helpers/accounts_helper.rb`
- `app/views/accounts/_account_sidebar_tabs.html.erb`
- `config/currencies.yml`
- account locale updates in German, English, Spanish, French, Hungarian, Dutch, and Polish
- report locale updates in Catalan, German, English, Spanish, French, Hungarian, Dutch, Polish, Brazilian Portuguese, Romanian, Simplified Chinese, and Traditional Chinese
- `app/controllers/reports_controller.rb`
- `app/views/reports/index.html.erb`
- `test/models/investment_test.rb`
- `test/controllers/reports_controller_test.rb`

### Database Changes

The fork adds four migrations:

- `db/migrate/20260509120000_create_statement_profiles_and_import_fields.rb`
- `db/migrate/20260509124000_add_statement_original_filename_to_imports.rb`
- `db/migrate/20260509124100_add_processing_progress_to_imports.rb`
- `db/migrate/20260510120000_create_auto_categorization_wizard_tables.rb`

`db/schema.rb` changes accordingly.

### Routes

The fork adds:

- `resources :auto_categorization_runs, path: "ai-category-wizard"` with retry, category creation, bootstrap, apply, category suggestion editing, and transaction suggestion editing routes.
- `post :retry_processing` under imports.

No routes are deleted in the fork-side ancestor comparison.

### Tests

The fork adds or updates tests for:

- AI category wizard controller, models, jobs, and helper support
- OpenAI category suggestions
- Codex-backed provider auth/client behavior
- Statement extraction and statement import behavior
- Import controller and statement-processing jobs
- Reports, categories, settings hosting, accounts, transactions, users, investment, chat, and provider registry behavior
- `test/javascript/statement_review_form_controller_test.mjs`
- statement fixtures: CPF, DBS, and IBKR import files

### OpenSpec Documentation

The fork adds OpenSpec material:

- `openspec/changes/add-singapore-aware-goals-tab/*`
- `openspec/changes/archive/2026-05-11-add-ai-category-wizard/*`
- `openspec/changes/harden-ai-provider-chat-reliability/*`
- `openspec/specs/ai-category-wizard/spec.md`

### Miscellaneous

Other changes include:

- `.env.example` and `.env.local.example`
- `.gitignore`
- `AGENTS.md`
- `CLAUDE.md`
- `Makefile`
- `config/initializers/filter_parameter_logging.rb`
- `config/schedule.yml`
- `app/controllers/concerns/accountable_resource.rb`
- `app/controllers/concerns/safe_pagination.rb`
- `app/controllers/family_merchants_controller.rb`
- `app/controllers/rules_controller.rb`
- `app/models/family.rb`
- `app/models/family/auto_merchant_detector.rb`
- `app/models/provider_merchant/enhancer.rb`
- `app/models/setting.rb`
- `app/models/user.rb`
- `vendor/javascript/robust-predicates.js`
- `.superpowers/brainstorm/...` generated brainstorming/session files

## Commit-Level Summary

Notable fork commits after the equivalent ancestor include:

- `Add Codex-backed LLM provider`
- `Fix Codex chat streaming responses`
- `Add monthly statement import workflow`
- `Add IBKR statement import support`
- `Group CPF statement rows by bucket`
- `Handle consolidated DBS statement imports`
- `Auto-refresh processing import pages`
- `Improve statement import review controls`
- `Expand account sidebar groups by default`
- `Preserve settings sidebar scroll position`
- `Add last month reports period`
- `Auto-enrich statement import transactions`
- `Document external Postgres compose setup`
- `Preserve single-account PDF transaction fallback`
- `Avoid merging incompatible statement accounts`
- `Add statement import coverage`
- `Add AI category wizard for transaction auto-categorization`
- `Address AI categorization review feedback`
- `Add OpenSpec for AI provider reliability`

## Reproduction Commands

```sh
git fetch upstream main
git merge-base --all HEAD upstream/main
git diff --shortstat 5280aaef2f25b9fcaeeac3fc49939acbd0b47799..HEAD
git diff --name-status 5280aaef2f25b9fcaeeac3fc49939acbd0b47799..HEAD
git diff --dirstat=files,0 5280aaef2f25b9fcaeeac3fc49939acbd0b47799..HEAD
```

To inspect the upstream-side equivalent ancestor:

```sh
git show --stat b74014ab4246403fdec09aeccb220b2b7eca21db
git diff --shortstat b74014ab4246403fdec09aeccb220b2b7eca21db..HEAD
```
