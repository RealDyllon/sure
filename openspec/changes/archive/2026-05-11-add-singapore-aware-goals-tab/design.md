## Context

The app already has the building blocks needed for a first version of Goals:

- Main navigation is defined in `app/views/layouts/application.html.erb`, with Reports and Budgets already present in the primary tab set.
- Reports already computes income, expense, savings-rate-adjacent, investment, and net worth data through `IncomeStatement`, `BalanceSheet`, and `InvestmentFlowStatement`.
- Budgets already has compact progress-card patterns and month-scoped spending data that can inform default expense assumptions.
- Investment accounts already include Singapore CPF subtypes: `cpf_ordinary`, `cpf_special`, `cpf_medisave`, `cpf_retirement`, and `cpf_other`.
- SRS is not currently represented as a first-class investment subtype, so v1 must support explicit user mapping instead of pretending it can always infer SRS.
- Users do not currently have a birthdate or current-age field, so age-based FIRE and CPF/SRS milestones need their own editable timeline assumption and a missing-age state.

The new Goals tab should be a planning surface, not a replacement for Reports. Reports explains what happened; Goals estimates where the user is relative to long-term targets and exposes the assumptions behind those estimates.

## Goals / Non-Goals

**Goals:**

- Add a new top-level Goals tab next to Reports and Budgets.
- Make the first screen useful immediately with auto-computed starter progress.
- Use a Financial Independence hero card as the primary Goals surface.
- Make FIRE Singapore-aware by default through liquid bridge and CPF/SRS later-bucket modeling.
- Allow users to deviate from Singapore defaults by editing assumptions and account bucket mappings.
- Add default supporting cards for emergency fund, debt payoff, savings rate, and custom targets.
- Keep calculations scoped to accounts the current user includes in finances.
- Normalize goal amounts to the family currency using existing converted-balance behavior and show review states when conversion is unavailable.
- Present results as estimates and scenarios rather than financial advice.

**Non-Goals:**

- Do not build a complete CPF LIFE payout simulator in v1.
- Do not import CPF or SRS data from government/bank providers as part of this change.
- Do not add a public API for goals in v1.
- Do not add behavioral assertions to rswag request specs.
- Do not implement tax optimization, withdrawal sequencing, Monte Carlo simulations, or country-specific planning beyond Singapore-aware defaults and editable assumptions.
- Do not make users complete a setup wizard before the Goals tab renders.

## Decisions

1. Add a dedicated Goals controller and route.

   Use explicit routes instead of overloading `resources :goals` for both virtual computed goals and persisted custom goals. `GoalsController#index` renders the dashboard, `Goals::FireController#show` or an equivalent route renders `/goals/fire`, `Goals::AssumptionsController` handles assumptions, and `FinancialGoalsController` handles persisted custom goal CRUD. This keeps virtual goal identifiers from colliding with database-backed custom goal IDs. The alternative was a single RESTful `GoalsController#show`, but that would mix computed goal names such as `fire` with persisted custom-goal IDs.

2. Store user-specific goal assumptions in a profile record.

   Add a `GoalProfile` or similarly named model scoped to `family_id` and `user_id`. Store editable assumptions such as planning region, current age or birth year, annual spending override, withdrawal rate, expected return, inflation, emergency-fund months, CPF access age, CPF LIFE age, SRS access age, skipped review prompts, and account role overrides. Store manual overrides separately from live inferred defaults so auto-first values continue to update until the user explicitly overrides them. This avoids overloading `User#preferences` with important planning state and keeps assumptions queryable/testable. The alternative was JSON-only preferences; that is cheaper initially but harder to validate, evolve, and test.

3. Represent custom goals separately from computed default goals.

   Add a `FinancialGoal` or similarly named model for user-created goals, scoped to `family_id` and `user_id`. Computed default goals like FIRE, emergency fund, debt payoff, and savings rate can be virtual cards produced by calculators. Custom goals need persistence for target amount, target currency, target date, funding accounts, status, and display order. Use a join table or equivalent validated relationship for funding accounts so deleted, unshared, or no-longer-finance-included account IDs can be ignored safely. The alternative was to persist every default goal as a row, but that adds setup and synchronization complexity before users have customized anything.

4. Use service objects for calculations.

   Add calculation services under a `Goals` namespace:

   - `Goals::DashboardBuilder`
   - `Goals::FireCalculator`
   - `Goals::EmergencyFundCalculator`
   - `Goals::DebtPayoffCalculator`
   - `Goals::SavingsRateCalculator`
   - `Goals::AccountClassifier`

   These services should consume `Current.family.balance_sheet(user:)`, `Current.family.income_statement(user:)`, current-user finance accounts, budgets, and persisted goal assumptions. This keeps controllers thin and makes the calculations testable. The alternative was controller-heavy aggregation, which would repeat the Reports controller pattern and make future scenario work harder.

5. Infer Singapore buckets conservatively.

   `Goals::AccountClassifier` should infer:

   - CPF later bucket from investment accounts with CPF subtypes.
   - Liquid bridge bucket from included taxable investment, cash, and other liquid asset accounts unless overridden.
   - Emergency-fund inclusion from cash-like depository accounts unless overridden.
   - SRS only from explicit user mapping until an SRS subtype exists.

   FIRE bucket roles and goal-specific inclusions are separate concepts. Each account has at most one FIRE role (`bridge`, `later`, or `excluded`), while emergency fund and custom goals maintain their own account inclusion sets. Emergency cash can therefore appear in the emergency-fund card and still count as bridge liquidity for FIRE, with copy clarifying that the views answer different questions and do not create new money. Users must be able to override account roles. This preserves Singapore-aware defaults without silently misclassifying important assets. The alternative was to add an SRS subtype immediately and rely on subtype inference, but existing data may still need mapping and some users may hold SRS in accounts that do not fit a new subtype cleanly.

6. Default FIRE calculation to a bridge-plus-later model.

   The FIRE hero should show one headline progress value, but the detail view must split progress into:

   - liquid bridge bucket: assets available before CPF/SRS-style later retirement support
   - CPF/SRS later bucket: locked or delayed-retirement assets

   V1 should use explicit, conservative formulas:

   - `annual_spending` comes from a manual override when present, otherwise a live inferred recent-spending value.
   - `fi_target = annual_spending / withdrawal_rate`.
   - `later_retirement_progress = (bridge_assets + later_assets) / fi_target`.
   - If current age and later access age are available, `bridge_target = annual_spending * max(later_access_age - estimated_fi_age, 0)`. The implementation can refine this with inflation/return assumptions, but later assets must never reduce this bridge target.
   - `bridge_progress = bridge_assets / bridge_target` when `bridge_target` is positive; otherwise bridge progress is satisfied.
   - Headline FI progress uses the limiting constraint: the lower of later retirement progress and bridge progress when bridge applies.
   - Estimated FI timing is found by projecting bridge assets, later assets, and ongoing contributions until both later retirement progress and bridge progress are satisfied.

   If current age or birth year is missing, the dashboard can show progress and estimated years-to-FI, but age-labeled CPF/SRS timeline milestones must be replaced with a review prompt. CPF access milestones default to 55 and 65 when Singapore planning mode is active, but are editable. SRS uses a separate editable access age because SRS treatment differs from CPF. The alternative was a generic net-worth divided by target calculation; that would be simpler but would hide the main Singapore planning risk.

7. Gate Singapore behavior by planning mode.

   `GoalProfile#planning_region` should default to Singapore when `family.country == "SG"`, family currency is SGD, or CPF subtypes are detected. Otherwise it defaults to generic. Users can switch planning mode, skip SRS prompts, or mark CPF/SRS not applicable. Singapore-specific prompts should not appear for generic/non-Singapore profiles unless the user enables Singapore assumptions.

8. Render first, then ask for review.

   Goals should always render with best-effort estimates. Missing or uncertain inputs appear as non-blocking prompts, such as "SRS was not detected" or "Annual spending is based on 3 months of data." Users can review assumptions from the FIRE card or a dedicated assumptions screen. The alternative was a first-run wizard, but that delays value and makes the new tab feel like configuration work.

9. Match the existing app UI.

   Use the app's Tailwind theme and existing component conventions: `bg-container`, `shadow-border-xs`, compact summary cards, `DS::Link`/button styles, `privacy-sensitive` on financial amounts, Lucide icons through the existing icon helper, and responsive grids similar to Reports/Budgets. The wireframes from brainstorming are structure only, not visual styling.

## Risks / Trade-offs

- CPF/SRS estimates may be mistaken or incomplete -> Show assumptions prominently, mark uncertain mappings, and allow users to override account roles and ages.
- A single headline FIRE percentage can oversimplify Singapore planning -> Always expose liquid bridge and CPF/SRS later-bucket progress in the hero/detail view.
- Age-based timelines can be misleading without a current age -> Require an age/birth-year assumption for age labels and otherwise show years-to-FI plus a review prompt.
- Debt payoff can be wrong if provider balances represent available credit rather than debt owed -> Use provider/account-type-specific owed amounts and show unavailable states when owed debt cannot be determined.
- Account mappings can become stale when sharing changes -> Validate persisted account IDs against `Current.user.finance_accounts` on every read/write and ignore deleted or no-longer-included accounts.
- Multi-currency targets and accounts can be misleading -> Store target currency, normalize calculations to family currency, and show review states when exchange rates are unavailable.
- Recent spending may be noisy -> Label the spending basis and allow manual annual-spend override.
- Shared-family/account access can produce confusing totals -> Scope calculations to the current user's finance accounts using existing account inclusion rules.
- More persisted models increase migration scope -> Keep v1 persistence focused on assumptions and custom goals; computed defaults remain virtual.
- Financial planning copy can sound like advice -> Use "estimated", "scenario", "based on current data", and "review assumptions"; avoid prescriptive recommendations.
- Supporting goal cards can become noisy -> Keep cards compact and route detail/setup into each card rather than expanding everything on the dashboard.

## Migration Plan

Additive migrations can introduce `goal_profiles`, `financial_goals`, and custom-goal account mappings without changing existing records. On first visit to Goals, create or lazily initialize a profile with inferred defaults derived from current data, while keeping manual overrides separate from live inferred values. Add explicit `dependent: :destroy` model associations and foreign-key behavior so family deletion and user purge continue to work. If the feature needs rollback, remove the nav/route/controller usage and leave the additive tables unused until a cleanup migration.

No public API endpoints are added, so no OpenAPI rswag documentation is needed.

## Open Questions

- Exact model names can be finalized during implementation, but the concepts should remain: one assumptions/profile record and one custom-goals record type.
- The first implementation can use a standard Rails page for the FIRE detail view. A modal/drawer can be added later if the app establishes that pattern elsewhere.
