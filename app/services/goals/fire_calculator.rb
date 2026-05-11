module Goals
  class FireCalculator
    Result = Data.define(
      :fi_target_money,
      :bridge_target_money,
      :bridge_assets_money,
      :later_assets_money,
      :later_retirement_progress,
      :bridge_progress,
      :headline_progress,
      :limiting_constraint,
      :estimated_fi_age,
      :estimated_years_to_fi,
      :review_prompts,
      :milestones,
      :bridge_accounts,
      :later_accounts
    )

    def initialize(user:, profile:, scenario: {})
      @user = user
      @profile = profile
      @family = user.family
      @scenario = scenario.to_h.symbolize_keys
    end

    def call
      classifier = Goals::AccountClassifier.new(user: user, profile: profile).call
      estimated_years = estimate_years_to_fi(classifier)
      estimated_age = current_age && estimated_years ? current_age + estimated_years : nil
      bridge_target = bridge_target_for_age(estimated_age || current_age, classifier, estimated_years || 0)
      later_progress = progress(total_assets(classifier), fi_target)
      bridge_progress = bridge_target.positive? ? progress(classifier.fire_bridge_balance.amount, bridge_target) : 1.to_d
      headline = bridge_target.positive? ? [ later_progress, bridge_progress ].min : later_progress

      Result.new(
        fi_target_money: money(fi_target),
        bridge_target_money: money(bridge_target),
        bridge_assets_money: classifier.fire_bridge_balance,
        later_assets_money: classifier.fire_later_balance,
        later_retirement_progress: later_progress,
        bridge_progress: bridge_progress,
        headline_progress: headline,
        limiting_constraint: bridge_progress < later_progress ? :bridge : :later_retirement,
        estimated_fi_age: estimated_age,
        estimated_years_to_fi: estimated_years,
        review_prompts: review_prompts(classifier),
        milestones: milestones,
        bridge_accounts: classifier.fire_bridge_accounts,
        later_accounts: classifier.fire_later_accounts
      )
    end

    private
      attr_reader :user, :profile, :family, :scenario

      def annual_spending
        @annual_spending ||= begin
          value = scenario[:annual_spending].presence || profile.annual_spending(inferred: inferred_annual_spending)
          value.to_d
        end
      end

      def withdrawal_rate
        @withdrawal_rate ||= begin
          value = (scenario[:withdrawal_rate].presence || profile.withdrawal_rate || 0.04).to_d
          value > 1 ? value / 100 : value
        end
      end

      def fi_target
        return 0.to_d if withdrawal_rate.zero?

        annual_spending / withdrawal_rate
      end

      def current_age
        profile.current_age.presence || (Date.current.year - profile.birth_year if profile.birth_year.present?)
      end

      def annual_contribution
        (scenario[:annual_contribution].presence || 0).to_d
      end

      def estimate_years_to_fi(classifier)
        (0..100).detect do |years|
          projected_total = projected_balance(total_assets(classifier), years, annual_contribution)
          projected_fi_target = fi_target_for_years(years)

          if current_age
            age = current_age + years
            projected_bridge = projected_balance(classifier.fire_bridge_balance.amount, years, annual_contribution)
            projected_bridge_target = bridge_target_for_age(age, classifier, years)

            projected_total >= projected_fi_target && (projected_bridge_target.zero? || projected_bridge >= projected_bridge_target)
          else
            projected_total >= projected_fi_target
          end
        end
      end

      def bridge_target_for_age(age, classifier, years = 0)
        return 0.to_d if annual_spending.zero? || age.blank?

        annual_spending_for_years(years) * [ later_access_age(classifier) - age, 0 ].max
      end

      def later_access_age(classifier)
        return [ profile.cpf_access_age, profile.srs_access_age ].max if classifier.fire_later_accounts.any? { |account| srs_account?(account) }

        profile.cpf_access_age
      end

      def srs_account?(account)
        account.name.to_s.match?(/\bsrs\b/i)
      end

      def progress(amount, target)
        return 1.to_d if target.zero?

        amount.to_d / target.to_d
      end

      def total_assets(classifier)
        classifier.fire_bridge_balance.amount + classifier.fire_later_balance.amount
      end

      def expected_return
        @expected_return ||= profile.expected_return.to_d
      end

      def inflation_rate
        @inflation_rate ||= profile.inflation_rate.to_d
      end

      def projected_balance(balance, years, annual_addition)
        return balance.to_d + annual_addition.to_d * years if expected_return.zero?

        factor = compound_factor(expected_return, years)
        contribution_growth = annual_addition.to_d * ((factor - 1) / expected_return)
        balance.to_d * factor + contribution_growth
      end

      def fi_target_for_years(years)
        return 0.to_d if withdrawal_rate.zero?

        annual_spending_for_years(years) / withdrawal_rate
      end

      def annual_spending_for_years(years)
        annual_spending * compound_factor(inflation_rate, years)
      end

      def compound_factor(rate, years)
        (1.to_d + rate.to_d) ** years
      end

      def inferred_annual_spending
        monthly = IncomeStatement.new(family, user: user).avg_expense(interval: "month")
        monthly.to_d * 12
      rescue
        0.to_d
      end

      def review_prompts(classifier)
        prompts = classifier.review_prompts.dup
        prompts << :current_age_missing if current_age.blank?
        prompts.uniq
      end

      def milestones
        {
          cpf_access_age: profile.cpf_access_age,
          cpf_life_age: profile.cpf_life_age,
          srs_access_age: profile.srs_access_age
        }
      end

      def money(amount)
        Money.new(amount, family.currency)
      end
  end
end
