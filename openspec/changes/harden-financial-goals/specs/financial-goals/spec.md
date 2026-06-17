## MODIFIED Requirements

### Requirement: Debt payoff goal tracks visible liabilities
The system SHALL show debt payoff progress using included liability accounts only when reliable debt-owed values are available, and SHALL surface an estimated payoff duration when minimum payment information is available for every reliable liability.

#### Scenario: Debt payoff uses liability balances
- **WHEN** the user has included liability accounts with reliable owed-balance values
- **THEN** the system shows total remaining debt and payoff progress based on those owed-balance values

#### Scenario: Debt payoff avoids available-credit balances
- **WHEN** a liability account balance represents available credit or another value that is not debt owed
- **THEN** the system excludes that account from payoff math and shows a review or unavailable state for that account

#### Scenario: Debt payoff estimates months from minimum payments
- **WHEN** every reliable liability account exposes a positive minimum or scheduled monthly payment, such as a credit card minimum payment or a fixed-rate loan scheduled payment
- **THEN** the system shows an estimated payoff duration in months derived from the total remaining debt divided by the sum of those monthly payments, converted to the family currency, and labels it as an estimate

#### Scenario: Debt payoff handles missing payment information
- **WHEN** one or more reliable liability accounts do not expose a usable minimum or scheduled monthly payment
- **THEN** the system shows total remaining debt and balance progress without an estimated payoff duration and indicates that payment information is unavailable

#### Scenario: Debt payoff handles unavailable FX for payments
- **WHEN** a minimum or scheduled monthly payment cannot be converted to the family currency
- **THEN** the system does not show an estimated payoff duration and surfaces a non-blocking review state

### Requirement: Users can edit goal assumptions and account treatment
The system SHALL allow users to review and override assumptions and account bucket mappings used by goal calculations, SHALL validate those assumptions before persisting them, and SHALL let saved scenarios clear inferred overrides intentionally.

#### Scenario: User edits FIRE assumptions
- **WHEN** a user changes planning region, current age or birth year, annual spending, withdrawal rate, expected return, inflation, CPF access age, CPF LIFE age, or SRS access age
- **THEN** the system persists those assumptions and recalculates Financial Independence progress using the updated values

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

#### Scenario: Blank annual contribution falls back to default
- **WHEN** a user submits the assumptions form with a blank annual contribution
- **THEN** the system persists the annual contribution as zero instead of rejecting the submission

#### Scenario: Impossible current age is rejected
- **WHEN** a user submits a current age outside a realistic human range
- **THEN** the system rejects the submission with a validation error and does not use that age in Financial Independence timing

#### Scenario: Saving a scenario clears the annual spending override
- **WHEN** a user saves a FIRE scenario with a blank annual spending field
- **THEN** the system clears the manual annual spending override so future calculations revert to the inferred spending value

#### Scenario: Saving a scenario rejects a blank withdrawal rate
- **WHEN** a user saves a FIRE scenario with a blank withdrawal rate
- **THEN** the system rejects the submission with a validation error instead of silently keeping the previous withdrawal rate
