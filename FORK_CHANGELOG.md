# Fork changelog

This changelog covers releases of [RealDyllon/sure](https://github.com/RealDyllon/sure).
Upstream changes remain in [we-promise/sure's releases](https://github.com/we-promise/sure/releases).

## Version convention

- `.sure-version` identifies the upstream base; `.fork-version` identifies this fork's release.
- Fork releases use `fork-vMAJOR.MINOR.PATCH` tags. Patch releases fix bugs; minor releases add features or refresh upstream; major releases introduce incompatible fork changes.
- Every release records its upstream tag and commit. Fork tags are immutable and do not trigger upstream's `v*` packaging workflows.
- Set `FORK_GITHUB_REPOSITORY=owner/repository` if distributing a different fork. The default is `RealDyllon/sure`; upstream stays `we-promise/sure`.
- Update `.fork-version`, move the relevant `Unreleased` notes into a dated entry, verify the app, and publish the matching GitHub release using that entry as its notes.

## Unreleased

## 0.1.0 — 2026-10-04

Upstream base: [v0.7.5-hotfix.1](https://github.com/we-promise/sure/releases/tag/v0.7.5-hotfix.1), commit [`789883081feda49fcfa8c7bc923cc77c9fe301ad`](https://github.com/we-promise/sure/commit/789883081feda49fcfa8c7bc923cc77c9fe301ad).

### Added

- Independent fork versioning, with upstream and fork release histories in the app. Installed releases are identified; the What's new popup remembers upstream and fork updates independently.
- Optional Codex-login integration for AI chat and statement extraction, selected explicitly with `LLM_PROVIDER=codex`. Existing upstream OpenAI and Anthropic providers remain available.
- Multi-account DBS PDF and DBS/UOB/PayLah/CPF/IBKR statement imports, account review, remembered matches, background extraction, protected PDF support, trades and closing-balance valuations. Original documents stay in the statement vault; positions remain informational.
- Private FIRE planning under Plan for users with Preview features enabled, separating accessible bridge assets from later retirement assets, with CPF/SRS roles and editable access ages.

### Changed

- Rebuilt the fork on stable upstream Sure. Upstream Wise syncing, transaction rules, Quick Categorize and category merging replace older custom categorization and cleanup tools.
- Release notes render locally with sanitized Markdown; a repository outage does not hide the other repository's notes. Release and running-commit links point to their correct repositories.

### Setup and compatibility

- **Legacy fork installations require a fresh database, new encryption keys and fresh upload storage.** Do not connect this release to the legacy database; migration histories differ. Back up the legacy installation separately before starting a clean installation. This release-note update does not reset an existing rebuilt installation.
- Use mise with Ruby 3.4.9, PostgreSQL, Redis and libvips. Install Ruby dependencies and JavaScript dependencies, then build the existing design tokens and Tailwind assets. See [the rebuild and setup guide](https://github.com/RealDyllon/sure/blob/fork-v0.1.0/docs/fork-rebuild.md) for commands and Codex configuration.
- The old financial-goals dashboard and its emergency-fund, debt and savings calculators are not restored. FX planning remains deferred.
- This first fork release provides source code; it does not include packaged desktop or mobile binaries.
