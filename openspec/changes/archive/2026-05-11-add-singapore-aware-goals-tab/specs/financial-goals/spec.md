## ADDED Requirements

### Requirement: Goals appears as a main navigation tab
The system SHALL provide a top-level Goals navigation item next to existing main tabs such as Reports and Budgets for users in the standard app layout.

#### Scenario: User opens Goals from main navigation
- **WHEN** an authenticated user selects Goals from the main navigation
- **THEN** the system renders the Goals dashboard for the current family and user

#### Scenario: Goals nav item shows active state
- **WHEN** an authenticated user is viewing a Goals page
- **THEN** the Goals navigation item is visually marked active using the app's existing navigation active-state behavior

### Requirement: Goals dashboard shows computed starter goals
The system SHALL render a Goals dashboard with a Financial Independence hero card and supporting cards for emergency fund, debt payoff, savings rate, and custom goals.

#### Scenario: Dashboard renders without prior setup
- **WHEN** a user visits Goals without previously configuring goal assumptions
- **THEN** the system renders best-effort goal progress using existing account, balance sheet, income statement, budget, and transaction data

#### Scenario: Dashboard uses privacy treatment for money values
- **WHEN** the Goals dashboard displays balances, targets, gaps, or contribution amounts
- **THEN** those values participate in the app's existing privacy-sensitive display behavior

#### Scenario: Dashboard handles missing data
- **WHEN** there is insufficient account, income, expense, or budget data to compute a goal confidently
- **THEN** the system shows an explanatory empty or review state for that goal without preventing the rest of the dashboard from rendering

### Requirement: Financial Independence goal is Singapore-aware by default
The system SHALL calculate the Financial Independence goal using Singapore-aware defaults when Singapore planning mode is active and SHALL distinguish liquid bridge assets from CPF/SRS-style later retirement assets.

#### Scenario: Singapore planning mode is inferred
- **WHEN** the family country is Singapore, the family currency is SGD, or included finance accounts contain CPF investment subtypes
- **THEN** the system enables Singapore planning assumptions by default

#### Scenario: Generic planning mode is used
- **WHEN** Singapore planning mode is not active and no CPF/SRS accounts are detected or mapped
- **THEN** the system uses generic Financial Independence assumptions and does not show CPF/SRS review prompts

#### Scenario: CPF accounts are detected
- **WHEN** included finance accounts use CPF investment subtypes such as CPF Ordinary, Special, MediSave, Retirement, or other CPF account
- **THEN** the system classifies those balances into the later retirement bucket by default

#### Scenario: SRS is not inferred automatically
- **WHEN** Singapore planning mode is active and no account has been explicitly mapped as SRS or marked SRS not applicable
- **THEN** the system shows a non-blocking review prompt allowing the user to mark an account as SRS or skip SRS mapping

#### Scenario: SRS prompt is skipped
- **WHEN** a user marks SRS as not applicable or skips SRS mapping
- **THEN** the system persists that choice and stops showing the SRS review prompt unless the user resets the choice

#### Scenario: Liquid bridge assets are calculated
- **WHEN** the user has included finance accounts that are not classified as CPF/SRS later retirement assets or excluded from goals
- **THEN** the system classifies eligible liquid accounts into the bridge bucket by default

#### Scenario: Locked retirement investments are not bridge defaults
- **WHEN** the user has included tax-deferred, tax-exempt, or tax-advantaged retirement investment accounts such as 401(k), IRA, SIPP, RRSP, pension, or superannuation subtypes
- **THEN** the system excludes those accounts from the default liquid bridge bucket unless the user explicitly maps them to bridge

#### Scenario: FIRE progress shows bucket split
- **WHEN** the Financial Independence goal is shown on the dashboard or detail view
- **THEN** the system shows both liquid bridge progress and CPF/SRS later-bucket progress in addition to the headline FI progress

### Requirement: Financial Independence calculations are explicit
The system SHALL calculate Financial Independence progress using defined v1 formulas so delayed-access assets do not satisfy pre-access bridge requirements.

#### Scenario: FI target is calculated
- **WHEN** annual spending and withdrawal rate are available
- **THEN** the system calculates the FI target as annual spending divided by withdrawal rate

#### Scenario: Later assets do not satisfy bridge requirements
- **WHEN** CPF/SRS-style later retirement assets are classified into the later bucket
- **THEN** the system excludes those later-bucket balances from liquid bridge progress

#### Scenario: Headline progress uses the limiting constraint
- **WHEN** both later retirement progress and bridge progress are available
- **THEN** the system calculates headline FI progress from the lower of the later-retirement constraint and the bridge constraint

#### Scenario: Age is required for age-labeled milestones
- **WHEN** the user has not provided current age or birth year
- **THEN** the system does not show age-labeled FI, CPF access, or CPF LIFE milestones and instead shows a non-blocking review prompt for timeline assumptions

#### Scenario: Years-to-FI can render without age
- **WHEN** annual spending, withdrawal rate, balances, contribution assumptions, and return assumptions are available but current age is missing
- **THEN** the system shows an estimated years-to-FI value without labeling it as a user age

#### Scenario: SRS has separate access assumptions
- **WHEN** an account is mapped as SRS
- **THEN** the system uses a separate editable SRS access age rather than treating SRS as identical to CPF

### Requirement: Users can edit goal assumptions and account treatment
The system SHALL allow users to review and override assumptions and account bucket mappings used by goal calculations.

#### Scenario: User edits FIRE assumptions
- **WHEN** a user changes planning region, current age or birth year, annual spending, withdrawal rate, expected return, inflation, CPF access age, CPF LIFE age, or SRS access age
- **THEN** the system persists those assumptions and recalculates Financial Independence progress using the updated values

#### Scenario: Manual spending override is invalid
- **WHEN** a user enters a negative or non-numeric annual spending override
- **THEN** the system rejects the assumption update with validation feedback and keeps calculators from using the invalid value

#### Scenario: User changes FIRE account role
- **WHEN** a user assigns an account to the bridge bucket, CPF/SRS later bucket, or excluded FIRE bucket
- **THEN** the system persists the mapping and applies it to future goal calculations

#### Scenario: Emergency inclusion is separate from FIRE role
- **WHEN** an account is included in the emergency fund calculation
- **THEN** the system does not remove that account from its FIRE bridge role unless the user explicitly changes the FIRE role

#### Scenario: User resets assumptions
- **WHEN** a user resets goal assumptions to defaults
- **THEN** the system replaces manual assumptions with inferred defaults based on current data and default Singapore-aware settings

#### Scenario: Inferred defaults remain live until overridden
- **WHEN** a user has not manually overridden an inferred assumption such as annual spending
- **THEN** the system recalculates that inferred value from current data on future dashboard loads

#### Scenario: Stale mapped accounts are ignored
- **WHEN** a persisted account mapping references an account that was deleted, unshared, or no longer included in the user's finances
- **THEN** the system ignores that account for calculations and shows a non-blocking review prompt when user action is useful

### Requirement: Financial Independence detail explains timeline and scenarios
The system SHALL provide a Financial Independence detail view that explains the timeline, bucket readiness, assumptions, and scenario levers behind the estimate.

#### Scenario: Detail view shows milestones
- **WHEN** a user opens the Financial Independence detail view
- **THEN** the system shows timeline milestones for now, estimated FI date or age, CPF access age, and CPF LIFE age

#### Scenario: Detail view shows assumptions
- **WHEN** a user opens the Financial Independence detail view
- **THEN** the system lists the active assumptions used to calculate the estimate

#### Scenario: Detail view shows scenario impact
- **WHEN** a user changes scenario inputs such as monthly investing or annual spending
- **THEN** the system shows the estimated impact on the Financial Independence date or age without immediately overwriting saved assumptions

#### Scenario: Scenario can be saved intentionally
- **WHEN** a user chooses to save a scenario as assumptions
- **THEN** the system persists the scenario values as goal assumptions and recalculates the dashboard

### Requirement: Emergency fund goal tracks cash runway
The system SHALL calculate emergency fund progress from cash-like included accounts against a configurable target number of expense months.

#### Scenario: Emergency fund uses default months
- **WHEN** a user has not configured an emergency fund target
- **THEN** the system uses a six-month expense target by default

#### Scenario: Emergency fund progress renders
- **WHEN** the user has cash-like included finance accounts and recent expense data
- **THEN** the system shows current emergency fund months and progress toward the target months

#### Scenario: Emergency account inclusion can be changed
- **WHEN** a user includes or excludes accounts from the emergency fund calculation
- **THEN** the system recalculates the emergency fund goal using the updated account set

#### Scenario: Emergency account inclusion can be explicitly empty
- **WHEN** a user saves emergency-fund account treatment with no emergency accounts selected
- **THEN** the system treats that empty selection as an explicit override and does not fall back to all cash-like accounts

#### Scenario: Emergency fund explains shared cash usage
- **WHEN** an emergency-fund account also counts as FIRE bridge liquidity
- **THEN** the system explains that the same account is being viewed through both goal calculations and is not double-counted within a single calculation

### Requirement: Debt payoff goal tracks visible liabilities
The system SHALL show debt payoff progress using included liability accounts only when reliable debt-owed values are available.

#### Scenario: Debt payoff uses liability balances
- **WHEN** the user has included liability accounts with reliable owed-balance values
- **THEN** the system shows total remaining debt and payoff progress based on those owed-balance values

#### Scenario: Debt payoff avoids available-credit balances
- **WHEN** a liability account balance represents available credit or another value that is not debt owed
- **THEN** the system excludes that account from payoff math and shows a review or unavailable state for that account

#### Scenario: Debt payoff ignores credit-balance liabilities
- **WHEN** a liability account has a negative balance because the account is overpaid or carries a credit
- **THEN** the system treats that account as zero debt owed instead of subtracting it from other debt balances

#### Scenario: Debt payoff estimates months when possible
- **WHEN** sufficient payment information is available for liabilities
- **THEN** the system shows an estimated payoff duration

#### Scenario: Debt payoff handles missing payment information
- **WHEN** payment information is unavailable
- **THEN** the system shows balance progress without an estimated payoff date

### Requirement: Savings rate goal tracks recent savings behavior
The system SHALL calculate a rolling savings rate from income and expense data and show it as a goal or metric card with an editable target when a target is available.

#### Scenario: Savings rate uses recent periods
- **WHEN** the user has recent income and expense data
- **THEN** the system calculates and displays a rolling savings rate using recent periods

#### Scenario: Savings rate excludes investment internal movements
- **WHEN** recent investment cash transactions have internal-movement activity labels such as Transfer, Sweep In, Sweep Out, or Exchange
- **THEN** the system excludes those entries from savings-rate income and expense totals

#### Scenario: Savings rate surfaces unavailable FX
- **WHEN** recent income or expense entries require a missing exchange rate
- **THEN** the system adds a non-blocking unavailable-FX review prompt instead of silently treating the entry as zero

#### Scenario: Savings rate handles missing income
- **WHEN** recent income is zero or unavailable
- **THEN** the system shows that savings rate cannot be calculated from current data

#### Scenario: Savings rate can be compared to estimated FIRE target
- **WHEN** Financial Independence assumptions are available
- **THEN** the system shows how the current savings rate relates to the user's estimated FIRE target or configured savings-rate target

#### Scenario: Savings rate target is unavailable
- **WHEN** neither a configured savings-rate target nor enough Financial Independence assumptions are available
- **THEN** the system shows savings rate as a metric without a progress percentage

### Requirement: Users can create custom target goals
The system SHALL allow users to create custom goals with a target amount, optional target date, and optional funding accounts.

#### Scenario: User creates custom goal
- **WHEN** a user enters a custom goal name, target amount, and optional target date
- **THEN** the system persists the custom goal, target currency, and optional target date for the current family and user

#### Scenario: Custom goal tracks selected accounts
- **WHEN** a custom goal has selected funding accounts
- **THEN** the system calculates progress from selected accounts that remain included in the user's finances toward the goal target

#### Scenario: Custom goal handles stale funding accounts
- **WHEN** a selected funding account is deleted, unshared, or no longer included in the user's finances
- **THEN** the system ignores the stale account and continues calculating the goal from valid funding accounts

#### Scenario: Custom goal can be updated or archived
- **WHEN** a user edits or archives a custom goal
- **THEN** the system updates the dashboard to reflect the changed custom goal state

#### Scenario: Saved custom goal exposes an edit path
- **WHEN** the Goals dashboard lists an existing custom goal
- **THEN** the system provides an edit form or link that lets the user update the goal target, date, currency, and funding accounts without archiving and recreating it

### Requirement: Goals copy is estimation-oriented
The system SHALL present goal outputs as estimates and planning scenarios rather than prescriptive financial advice.

#### Scenario: Goal estimates use cautious wording
- **WHEN** the system displays projected dates, ages, gaps, or scenario outcomes
- **THEN** the copy uses terms such as estimated, based on current data, scenario, and review assumptions

#### Scenario: Review prompts do not block dashboard usage
- **WHEN** assumptions or mappings need review
- **THEN** the system shows non-blocking prompts and continues to render available goal estimates

### Requirement: Goal calculations use family currency
The system SHALL normalize goal calculations to the family currency while preserving each custom goal's target currency.

#### Scenario: Account balances use converted values
- **WHEN** accounts have currencies different from the family currency
- **THEN** the system uses existing converted-balance behavior to calculate dashboard progress in the family currency

#### Scenario: FX is unavailable
- **WHEN** a required currency conversion is unavailable
- **THEN** the system excludes the affected amount from progress and shows a non-blocking review state

#### Scenario: Custom goal target currency is preserved
- **WHEN** a user creates a custom goal with a target currency
- **THEN** the system stores the target currency and displays progress in the target or family currency according to the goal display settings
