## 1. Data Model

- [x] 1.1 Add a migration for `goal_profiles` scoped to family and user, with planning region, current age or birth year, money/percentage assumption overrides, CPF/SRS milestone ages, emergency fund target months, skipped prompt state, and JSON account role overrides.
- [x] 1.2 Add a migration for `financial_goals` scoped to family and user, with goal type/name, target amount, target currency, optional target date, status, position, and metadata.
- [x] 1.3 Add a migration for custom goal funding account mappings or an equivalent validated relationship, with foreign keys that tolerate deleted/unshared accounts safely.
- [x] 1.4 Implement `GoalProfile` associations, validations, default builders, percentage normalization, planning-region defaults, skipped-prompt helpers, and helpers for live inferred values versus manual overrides.
- [x] 1.5 Implement `FinancialGoal` associations, money handling, target currency handling, status enum, custom-goal validations, ordering, and archive behavior.
- [x] 1.6 Add family/user associations for goal profiles and financial goals with explicit `dependent: :destroy` or equivalent foreign-key behavior so family deletion and user purge continue to work.
- [x] 1.7 Validate persisted account mappings against the current user's finance-included accounts and ignore deleted, unshared, or no-longer-included account IDs on read and write.

## 2. Goal Calculation Services

- [x] 2.1 Implement `Goals::AccountClassifier` to classify included finance accounts into FIRE bridge, FIRE later, FIRE excluded, emergency inclusion, liability eligibility, and custom-goal funding roles.
- [x] 2.2 Make `Goals::AccountClassifier` infer CPF later-bucket accounts from Singapore CPF investment subtypes only when Singapore planning mode is active or CPF accounts are detected, and require explicit mapping for SRS accounts.
- [x] 2.3 Implement Singapore planning mode defaults from family country, SGD currency, or detected CPF subtypes, with a generic planning mode for non-Singapore users and persisted "SRS not applicable" state.
- [x] 2.4 Implement `Goals::FireCalculator` with explicit v1 formulas for annual spending, withdrawal-rate FI target, bridge target, later-retirement progress, bridge progress, limiting-constraint headline progress, projection-based FI timing, and review prompts.
- [x] 2.5 Make `Goals::FireCalculator` require current age or birth year for age-labeled FI/CPF/SRS milestones and fall back to years-to-FI plus a review prompt when age is missing.
- [x] 2.6 Implement `Goals::EmergencyFundCalculator` using cash-like account inclusions and configurable target expense months, without removing those accounts from FIRE bridge calculations.
- [x] 2.7 Implement `Goals::DebtPayoffCalculator` using only reliable debt-owed values and excluding or flagging accounts whose balance represents available credit or another non-debt value.
- [x] 2.8 Implement `Goals::SavingsRateCalculator` using rolling recent income and expenses, editable/configured targets when available, and a metric-only state when no target can be inferred.
- [x] 2.9 Implement `Goals::CustomGoalCalculator` for persisted custom goals, target currency, selected valid funding accounts, and stale-account exclusion.
- [x] 2.10 Implement family-currency normalization for all dashboard calculations using existing converted-balance behavior and review states for unavailable FX.
- [x] 2.11 Implement `Goals::DashboardBuilder` to compose hero card, supporting cards, custom goals, assumptions, and review prompts for the current family/user.

## 3. Routes And Controllers

- [x] 3.1 Add explicit Goals routes for dashboard, FIRE detail, assumptions edit/update, account role mapping update, custom goal create/update/archive, and scenario preview without mixing virtual goal names with database IDs.
- [x] 3.2 Implement `GoalsController#index` to load the dashboard builder and render the main Goals dashboard.
- [x] 3.3 Implement a dedicated FIRE detail action such as `Goals::FireController#show` for the Financial Independence detail view.
- [x] 3.4 Implement assumption update actions that persist `GoalProfile` changes and redirect or Turbo-update the affected goal surface.
- [x] 3.5 Implement custom goal create/update/archive actions scoped to the current family and user.
- [x] 3.6 Guard all actions so users can only use accounts and goals accessible through their current family and finance-account scope.
- [x] 3.7 Implement scenario preview actions that do not overwrite saved assumptions unless the user explicitly saves the scenario.

## 4. Navigation And UI

- [x] 4.1 Add the Goals item to desktop navigation next to Reports and Budgets, with locale entries and active-state behavior.
- [x] 4.2 Define and implement mobile navigation treatment for Goals, including whether the bottom nav supports six items or moves Assistant/another item behind an alternate entry point.
- [x] 4.3 Build the Goals dashboard header and responsive card layout using the app's Tailwind theme, design system buttons/links, and existing card conventions.
- [x] 4.4 Build the Financial Independence hero card with headline progress, estimated FI age/date or years-to-FI fallback, bridge bucket progress, CPF/SRS later-bucket progress, gap to target, review prompts, and edit/detail actions.
- [x] 4.5 Build supporting cards for emergency fund, debt payoff, savings rate, and custom goal entry.
- [x] 4.6 Build the Financial Independence detail view with timeline milestones, bucket readiness, assumptions summary, scenario levers, missing-age states, and non-blocking review prompts.
- [x] 4.7 Build assumptions and account-role editing UI that lets users override planning region, current age/birth year, annual spend, rates, CPF/SRS ages, emergency months, and account bucket mappings.
- [x] 4.8 Build custom goal form UI for target amount, target currency, optional target date, selected funding accounts, and archive/edit actions.
- [x] 4.9 Ensure all monetary values use `privacy-sensitive` and all copy uses estimation-oriented language.
- [x] 4.10 Add empty, missing-data, unavailable-FX, stale-account, unsupported-debt, and insufficient-history states that do not block the rest of the dashboard.

## 5. Localization And Copy

- [x] 5.1 Add English locale keys for navigation, dashboard titles, card labels, assumptions, review prompts, scenario labels, empty states, and validation errors.
- [x] 5.2 Use Singapore-aware copy for CPF/SRS defaults while keeping assumptions editable for users who deviate from the default model.
- [x] 5.3 Avoid financial-advice wording by using "estimated", "scenario", "based on current data", "estimated FIRE target", and "review assumptions" in projections and prompts.
- [x] 5.4 Add explanatory copy for accounts that appear in both emergency-fund and FIRE bridge views without being double-counted inside a single calculation.

## 6. Tests

- [x] 6.1 Add model tests for `GoalProfile` defaults, planning-region detection, skipped prompts, validations, account-role overrides, live inferred values, manual overrides, and reset behavior.
- [x] 6.2 Add model tests for `FinancialGoal` custom goal validation, money handling, target currency, status transitions, account scoping, ordering, and archive behavior.
- [x] 6.3 Add model or association tests for dependent destroy behavior on user purge and family deletion.
- [x] 6.4 Add service tests for CPF account detection, explicit SRS mapping, SRS not-applicable behavior, generic planning mode, bridge bucket classification, emergency account inclusion, and account exclusions.
- [x] 6.5 Add service tests for FIRE target/progress formulas, limiting-constraint headline progress, bucket split, missing-age fallback, estimated timeline, and scenario preview behavior.
- [x] 6.6 Add service tests for emergency fund, debt payoff reliable-owed-balance handling, available-credit exclusion, savings rate, currency conversion, unavailable FX, and custom goal calculators across complete and insufficient-data states.
- [x] 6.7 Add controller tests for Goals dashboard, FIRE detail, assumptions update, account mapping update, custom goal create/update/archive, family scoping, stale account mappings, and inaccessible account rejection.
- [x] 6.8 Add integration or system coverage for opening Goals from main navigation, mobile nav behavior, reviewing FIRE assumptions, mapping or skipping SRS, and seeing dashboard progress update.

## 7. Verification

- [x] 7.1 Run targeted model and service tests for goals.
- [x] 7.2 Run targeted controller/system tests for goals navigation and UI behavior.
- [x] 7.3 Run `bin/rails test` or the narrowest reliable test subset covering changed Rails areas.
- [x] 7.4 Run `bin/rubocop` and fix offenses in changed Ruby files.
- [x] 7.5 Confirm no `spec/requests/api/v1/` rswag files are required because this change adds no public API endpoint.

## 8. PR #11 Review Follow-Up

- [x] 8.1 Exclude delayed-access or tax-advantaged retirement investment accounts, such as 401(k), IRA, SIPP, RRSP, pension, and superannuation subtypes, from default FIRE bridge classification unless the user explicitly maps them.
- [x] 8.2 Preserve an explicit empty emergency-fund account selection so a saved "no emergency accounts" override does not fall back to every cash-like account.
- [x] 8.3 Clamp credit-balance liability accounts to zero in debt payoff totals so overpaid cards or loans do not reduce remaining debt.
- [x] 8.4 Exclude investment internal-movement activity labels (`Transfer`, `Sweep In`, `Sweep Out`, `Exchange`) from savings-rate income and expense totals.
- [x] 8.5 Surface unavailable FX in savings-rate calculations instead of silently treating unconverted cashflow as zero.
- [x] 8.6 Validate manual annual spending overrides as numeric and non-negative before saving assumptions.
- [x] 8.7 Provide a dashboard edit path for saved custom goals that submits through the existing update route without forcing users to archive and recreate goals.
- [x] 8.8 Reply to and resolve the seven PR #11 review threads after implementation and verification.
