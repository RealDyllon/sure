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
      bridge_target = bridge_target_for_age(estimated_age || current_age)
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
        if current_age
          (0..100).detect do |years|
            age = current_age + years
            projected_bridge = classifier.fire_bridge_balance.amount + annual_contribution * years
            projected_total = total_assets(classifier) + annual_contribution * years
            projected_bridge_target = bridge_target_for_age(age)

            projected_total >= fi_target && (projected_bridge_target.zero? || projected_bridge >= projected_bridge_target)
          end
        else
          return 0 if total_assets(classifier) >= fi_target
          return nil unless annual_contribution.positive?

          ((fi_target - total_assets(classifier)) / annual_contribution).ceil
        end
      end

      def bridge_target_for_age(age)
        return 0.to_d if annual_spending.zero? || age.blank?

        annual_spending * [ later_access_age - age, 0 ].max
      end

      def later_access_age
        profile.cpf_access_age
      end

      def progress(amount, target)
        return 1.to_d if target.zero?

        amount.to_d / target.to_d
      end

      def total_assets(classifier)
        classifier.fire_bridge_balance.amount + classifier.fire_later_balance.amount
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
