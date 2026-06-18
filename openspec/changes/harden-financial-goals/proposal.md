## Why

The Goals tab shipped as a Singapore-aware FIRE planning surface, but a review found correctness bugs, spec-compliance gaps, and missing localization. A few inputs are silently swallowed or unbounded, the emergency fund and debt payoff cards do not surface the months-based metrics the spec requires, and roughly forty user-facing strings are hardcoded in views instead of going through the locale layer the rest of the app uses. This change hardens the shipped behavior and closes those gaps without a setup wizard or breaking changes.

## What Changes

- Narrow over-broad `rescue` clauses in FIRE and emergency fund calculators so real bugs are not masked as "no spending data."
- Bound `GoalProfile#current_age` so impossible ages do not produce nonsensical `estimated_fi_age` values.
- Allow blank `annual_contribution` submissions to fall back to the column default instead of erroring, matching the existing `allow_blank` pattern on other assumption fields.
- Fix `Goals::FireController#save_scenario` so clearing the annual spending field actually clears the override (reverting to inferred spending) instead of being silently dropped by `compact_blank`, while clearing the withdrawal rate surfaces a validation error.
- Add a current-months-of-runway value to the emergency fund card alongside the money figures.
- Add an estimated payoff duration to the debt payoff card when minimum payment information is available, with a balance-only fallback when it is not.
- Extract hardcoded Goals view strings into `config/locales/views/goals/en.yml`, mirroring the existing `reports/en.yml` structure.
- Deduplicate `Goals::AccountClassifier` work per dashboard load by computing it once in `Goals::DashboardBuilder` and injecting it into the calculators that need it.
- Add clarifying comments on display-only assumption fields and percentage normalization edge cases.
- No breaking changes. No public API endpoints are added or modified, so OpenAPI rswag artifacts are not required.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `financial-goals`: Tighten input validation and error handling, surface emergency fund months and debt payoff duration on the dashboard, and move Goals view copy into the locale layer.

## Impact

- **Code**: `app/models/goal_profile.rb`, `app/controllers/goals/fire_controller.rb`, `app/services/goals/{fire,emergency_fund,debt_payoff,dashboard_builder}_calculator.rb`, and the Goals views under `app/views/goals/`.
- **Locales**: `config/locales/views/goals/en.yml` gains keys for dashboard cards, FIRE detail, assumptions, review prompts, and empty states.
- **Tests**: `test/models/goal_profile_test.rb`, `test/controllers/goals_controller_test.rb`, and `test/services/goals/` gain coverage for the new validation, scenario-clearing, months, duration, and locale-key behaviors.
- **No migrations**: all changes are code, locale, and test only.
- **No API changes**: no `spec/requests/api/v1/` rswag files are affected.
