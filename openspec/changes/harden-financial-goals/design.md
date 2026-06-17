## Context

The Goals tab shipped a Singapore-aware FIRE planning surface with supporting cards for emergency fund, debt payoff, savings rate, and custom goals. A review of that implementation found a handful of correctness bugs, two spec-compliance gaps, and a localization gap:

- `Goals::FireCalculator` and `Goals::EmergencyFundCalculator` use bare `rescue` around `IncomeStatement#avg_expense`, which can mask real errors as "no spending data." `avg_expense` already returns `0` on missing data, so the rescue is over-broad.
- `GoalProfile#current_age` is bounded only by `greater_than: 0`, so impossible ages flow into `estimated_fi_age`.
- `GoalProfile#annual_contribution` validates `numericality: { >= 0 }` without `allow_blank`, so an empty field in the assumptions form errors instead of reverting to the column default of `0`.
- `Goals::FireController#save_scenario` builds its update hash with `.compact_blank`, so clearing the annual spending field silently keeps the old override instead of reverting to inferred spending.
- The emergency fund card shows money figures but not the "current months of runway" the spec requires.
- The debt payoff card shows total debt but never an estimated payoff duration, even when minimum payment data is available. Liability models already expose payments: `CreditCard#minimum_payment_money` and `Loan#monthly_payment` (fixed-rate only).
- Roughly forty user-facing strings in the Goals views are hardcoded rather than routed through `config/locales/views/goals/en.yml`, unlike the Reports views.
- `Goals::AccountClassifier` is constructed and run twice per dashboard load — once inside `FireCalculator`, once inside `EmergencyFundCalculator`.

## Goals / Non-Goals

**Goals:**

- Narrow the over-broad rescue clauses so real errors surface while preserving the no-data fallback.
- Bound `current_age` to a realistic maximum.
- Let blank `annual_contribution` fall back to its column default.
- Make `save_scenario` actually clear the annual spending override when the field is cleared, and surface a validation error when the withdrawal rate is cleared.
- Surface current months of runway on the emergency fund card.
- Surface an estimated payoff duration on the debt payoff card when minimum payment information is available, with a balance-only fallback.
- Move Goals view copy into the locale layer.
- Compute `Goals::AccountClassifier` once per dashboard load and reuse it.

**Non-Goals:**

- No CPF LIFE payout simulation.
- No debt snowball/avalanche optimizer; the duration estimate is a simple ratio, labeled as an estimate.
- No new DB migrations, no public API endpoints, no rswag changes.
- No custom-goal position reordering UI.
- No changes to the savings-rate 3-month window.
- No translation to non-English locales (English keys only; other locales can follow).

## Decisions

1. **Narrow rescue to `StandardError`.**
   Replace `rescue` with `rescue StandardError` in the two inferred-spending call sites and add a comment that `IncomeStatement#avg_expense` returns `0` on no data, so this only guards against unexpected errors. Alternative: remove the rescue entirely since `avg_expense` returns `0`. Rejected — keeping a narrow guard is safer if `IncomeStatement` internals change, and it preserves the existing fallback semantics.

2. **Bound `current_age` with `less_than: 150`.**
   Add to the existing `numericality` validator. 150 is a conservative human-maximum placeholder. Alternative: derive from `birth_year`. Rejected — `current_age` and `birth_year` are independent optional fields; cross-field validation adds complexity for little gain.

3. **`allow_blank: true` for `annual_contribution`.**
   The column has `default: 0, null: false`, so a blank submission coerces to `0` once persisted. `allow_blank` lets the validator skip nil/empty, matching the existing pattern on `annual_spending_override` and `savings_rate_target`. Alternative: coerce in the controller. Rejected — model-level is the right place for numeric guards and is consistent with sibling fields.

4. **Explicit blank mapping in `save_scenario`.**
   Drop `.compact_blank`. Build the hash so that `annual_spending` blank maps to `nil` (clears the override → reverts to inferred), `annual_contribution` blank maps to `0` (the default), and `withdrawal_rate` blank is passed through so the model's `numericality` validation surfaces a 422. This matches the existing `GoalProfile#reset_assumption!` semantics for spending.

5. **Emergency fund `current_months`.**
   Add `current_months` to `Goals::EmergencyFundCalculator::Result` as `monthly_spending.zero? ? nil : (available / monthly_spending).round(1)`. The guard uses `monthly_spending.zero?` (a direct divide-by-zero guard) rather than `target.positive?`; the two are equivalent given `emergency_fund_months` is validated `> 0`, but the direct guard is more robust if the months default ever changes. Compute `monthly_spending` once and reuse for both the target and `current_months`. Render it on the card as "Current: X.X months" alongside the money figures.

6. **Debt payoff duration via minimum payments.**
   Add `estimated_months`, `has_payment_info`, and `monthly_payment_money` to `Goals::DebtPayoffCalculator::Result`. For each reliable debt account, derive a monthly payment in the family currency: `CreditCard` via `minimum_payment_money`, `Loan` via `monthly_payment` (which returns nil for non-fixed-rate). Sum payments and compute `estimated_months = (total_debt / total_monthly_payments).ceil` when every reliable account has a positive payment; otherwise `has_payment_info = false` and the card shows a balance-only state. Multi-currency payments convert to the family currency with FX-unavailable fallback to `has_payment_info = false`. The ratio ignores interest accruing above the minimum; this is acceptable for an "estimated" v1 value and is documented in the card copy. Alternative: iterative balance projection with per-account interest. Rejected for v1 complexity; the Loan `monthly_payment` already amortizes interest internally for fixed-rate loans.

7. **Inject `AccountClassifier` from `DashboardBuilder`.**
   `Goals::FireCalculator` and `Goals::EmergencyFundCalculator` accept an optional `classifier:` kwarg defaulting to `nil`; when nil they compute one (preserves standalone test usage). `Goals::DashboardBuilder` computes the classifier once and passes it to both. This halves the per-request account iteration for users with many accounts.

8. **i18n extraction.**
   Add keys to `config/locales/views/goals/en.yml` mirroring the `reports/en.yml` structure: `goals.index.*`, `goals.fire.*`, `goals.assumptions.*`, `goals.emergency_fund.*`, `goals.debt_payoff.*`, `goals.savings_rate.*`, `goals.custom_goals.*`, `goals.review_prompts.*`. Replace hardcoded strings in `goals/index.html.erb`, `goals/fire/show.html.erb`, `goals/assumptions/show.html.erb`, and `_review_prompts.html.erb` with `t(...)` calls. Keep the existing `goals.fire.title` and sibling keys.

## Risks / Trade-offs

- [Debt duration ratio can mislead when minimum payments barely cover interest] → Label the value "estimated", document the simplification in card copy, and fall back to balance-only when payments are missing.
- [Clearing withdrawal rate now 422s where it previously silently kept the old value] → This is intended behavior (withdrawal rate is non-null with a default); the error path already renders validation errors on the FIRE page.
- [i18n extraction changes many view lines] → Keep keys structural and add a locale-key existence test to lock them in.
- [AccountClassifier injection changes calculator constructors] → Optional kwarg with nil-default keeps existing tests and standalone usage working.

## Migration Plan

No migrations. All changes are code, locale, and test. Rollback is reverting the diff; the additive `Result` fields and locale keys are not load-bearing for existing flows.
