## Why

Users can see what happened in Reports and control monthly spending in Budgets, but there is no first-class place to understand progress toward long-term financial goals. A Goals tab creates a planning surface for FIRE, emergency reserves, debt payoff, savings rate, and custom targets, with Singapore-aware defaults for users who need CPF/SRS-aware planning.

## What Changes

- Add a new main navigation tab named Goals next to Reports and Budgets.
- Add a Goals dashboard that opens directly to progress, not a setup wizard.
- Add a Financial Independence hero card with Singapore-aware defaults, including liquid bridge progress and CPF/SRS later-bucket progress.
- Add a Financial Independence detail view with timeline, bucket readiness, assumptions, and scenario levers.
- Add compact default goal cards for emergency fund, debt payoff, savings rate, and a custom target goal.
- Auto-compute starter values from existing account, balance sheet, income statement, budget, and transaction data where possible.
- Let users review and override assumptions, included accounts, target amounts, dates, and Singapore-specific treatment.
- Define v1 Financial Independence calculations so CPF/SRS-style later assets cannot satisfy pre-access bridge requirements.
- Support editable age/timeline assumptions and show a missing-age review state when an age-based timeline cannot be calculated.
- Gate Singapore-specific prompts to Singapore planning mode, SGD/CPF-detected families, or users who explicitly enable Singapore assumptions.
- Show non-blocking review prompts when important inputs cannot be inferred, such as SRS account mapping.
- Tighten PR review-discovered edge cases: locked retirement investments do not default to FIRE bridge assets, explicit empty emergency-account selections are preserved, negative liability balances do not reduce debt, investment internal transfers do not affect savings rate, savings-rate FX gaps are surfaced, manual spending overrides are validated, and saved custom goals can be edited from the dashboard.
- Avoid financial-advice language by presenting projections as estimates and scenarios.
- No breaking changes.

## Capabilities

### New Capabilities
- `financial-goals`: Goal tracking and planning for FIRE, emergency fund, debt payoff, savings rate, and custom targets.

### Modified Capabilities

None.

## Impact

- Adds Rails routes, controller actions, models/services, views, helpers, locales, and tests for the new Goals tab.
- Reuses existing app layout navigation, design system components, account scoping, privacy-sensitive formatting, balance sheet data, income statement data, budget data, and investment account subtype metadata.
- Adds persistence for goal preferences, assumptions, account inclusion overrides, and custom goals.
- Does not add public API endpoints, so OpenAPI rswag artifacts are not required.
