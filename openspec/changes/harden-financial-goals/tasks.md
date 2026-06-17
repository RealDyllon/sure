## 1. Correctness And Safety

- [x] 1.1 Narrow bare `rescue` to `rescue StandardError` in `Goals::FireCalculator#inferred_annual_spending` and `Goals::EmergencyFundCalculator#inferred_annual_spending`, with a clarifying comment.
- [x] 1.2 Bound `GoalProfile#current_age` with `less_than: 150` in the existing `numericality` validator.
- [x] 1.3 Add `allow_blank: true` to the `GoalProfile#annual_contribution` validation.
- [x] 1.4 Replace `.compact_blank` in `Goals::FireController#scenario_goal_profile_params` with explicit blank mapping: annual spending blank to `nil`, annual contribution blank to `0`, withdrawal rate blank passed through to surface a validation error.

## 2. Emergency Fund Months

- [x] 2.1 Add `current_months` to `Goals::EmergencyFundCalculator::Result` and compute it as `available / monthly_spending` (rounded to 1 decimal) when the target is positive, otherwise `nil`.
- [x] 2.2 Render current months of runway on the emergency fund card in `goals/index.html.erb` alongside the money figures.

## 3. Debt Payoff Duration

- [x] 3.1 Add `estimated_months`, `has_payment_info`, and `monthly_payment_money` to `Goals::DebtPayoffCalculator::Result`.
- [x] 3.2 Derive a per-account monthly payment in the family currency using `CreditCard#minimum_payment_money` and `Loan#monthly_payment`, with FX-unavailable fallback to `has_payment_info = false`.
- [x] 3.3 Compute `estimated_months = (total_debt / total_monthly_payments).ceil` when every reliable account has a positive payment; otherwise `has_payment_info = false`.
- [x] 3.4 Render the estimated duration on the debt payoff card when `has_payment_info`, with a balance-only fallback and an FX-unavailable review state.

## 4. Localization

- [x] 4.1 Add English locale keys to `config/locales/views/goals/en.yml` for dashboard titles, card labels, FIRE detail, assumptions, review prompts, emergency fund, debt payoff, savings rate, custom goals, and empty states, mirroring the `reports/en.yml` structure.
- [x] 4.2 Replace hardcoded strings in `goals/index.html.erb` with `t(...)` calls.
- [x] 4.3 Replace hardcoded strings in `goals/fire/show.html.erb` with `t(...)` calls.
- [x] 4.4 Replace hardcoded strings in `goals/assumptions/show.html.erb` with `t(...)` calls.
- [x] 4.5 Replace hardcoded strings in `goals/_review_prompts.html.erb` with `t(...)` calls.

## 5. Performance

- [x] 5.1 Add an optional `classifier:` kwarg (default `nil`) to `Goals::FireCalculator` and `Goals::EmergencyFundCalculator`, reusing it when provided and computing one when not.
- [x] 5.2 Compute `Goals::AccountClassifier` once in `Goals::DashboardBuilder` and pass it into the FIRE and emergency fund calculators.

## 6. Polish

- [x] 6.1 Add a comment in `Goals::FireCalculator#milestones` noting `cpf_life_age` is display-only pending a future CPF LIFE payout simulator.
- [x] 6.2 Add a comment in `GoalProfile#normalize_percentage_fields` documenting the `1.5 -> 0.015` normalization edge.

## 7. Tests

- [x] 7.1 Add `GoalProfileTest` cases: reject `current_age = 200`; blank `annual_contribution` is valid.
- [x] 7.2 Add `GoalsControllerTest` cases: blank `annual_contribution` in a full assumptions submission redirects and persists `0`; `save_scenario` with blank annual spending clears the override; `save_scenario` with blank withdrawal rate renders 422.
- [x] 7.3 Extend `GoalsSupportingCalculatorsTest` emergency fund cases to assert `current_months` correctness and `nil` when the target is zero.
- [x] 7.4 Add `GoalsSupportingCalculatorsTest` debt payoff cases: duration with minimum payments present, balance-only fallback when a payment is missing, and FX-unavailable fallback.
- [x] 7.5 Add `GoalsFireCalculatorTest` case: calculator accepts an injected `classifier:` and reuses it instead of constructing a new one.
- [x] 7.6 Extend the `GoalsControllerTest` locale-key existence test to cover the new English keys added in task 4.1.

## 8. Verification

- [x] 8.1 Run `bin/rubocop` on all changed `app/` and `test/` files and fix any offenses.
- [x] 8.2 Run the targeted goals test subset: `test/models/goal_profile_test.rb`, `test/models/financial_goal_test.rb`, `test/models/goals_association_test.rb`, `test/services/goals/`, `test/controllers/goals_controller_test.rb`, `test/controllers/financial_goals_controller_test.rb`, `test/system/goals_test.rb`.
- [x] 8.3 Confirm `openspec status --change harden-financial-goals` shows the change complete with all tasks checked.
