module Goals
  class AccountClassifier
    LOCKED_RETIREMENT_INVESTMENT_SUBTYPES = %w[
      401k roth_401k 403b 457b tsp ira roth_ira sep_ira simple_ira
      sipp workplace_pension_uk rrsp dpsp prpp lira rrif lif lrif prif rlif
      super smsf pension retirement pillar_3a riester nps apy ppf ssy
    ].freeze

    Result = Data.define(
      :fire_bridge_accounts,
      :fire_later_accounts,
      :fire_excluded_accounts,
      :emergency_accounts,
      :fire_bridge_balance,
      :fire_later_balance,
      :review_prompts,
      :fx_unavailable
    ) do
      def fx_unavailable? = fx_unavailable
    end

    def initialize(user:, profile:)
      @user = user
      @profile = profile
      @family = user.family
    end

    def call
      bridge_accounts = []
      later_accounts = []
      excluded_accounts = []
      prompts = []

      accounts.each do |account|
        case fire_role_for(account)
        when "bridge"
          if asset_account?(account)
            bridge_accounts << account
          else
            excluded_accounts << account
          end
        when "later"
          if asset_account?(account)
            later_accounts << account
          else
            excluded_accounts << account
          end
        when "excluded"
          excluded_accounts << account
        else
          if cpf_account?(account) && singapore_context?
            later_accounts << account
          elsif default_bridge_account?(account)
            bridge_accounts << account
          else
            excluded_accounts << account
          end
        end
      end

      prompts << :srs_mapping if srs_prompt_needed?(later_accounts)
      bridge_balance, bridge_fx_unavailable = sum_balances(bridge_accounts)
      later_balance, later_fx_unavailable = sum_balances(later_accounts)
      fx_unavailable = bridge_fx_unavailable || later_fx_unavailable
      prompts << :fx_unavailable if fx_unavailable

      Result.new(
        fire_bridge_accounts: bridge_accounts,
        fire_later_accounts: later_accounts,
        fire_excluded_accounts: excluded_accounts,
        emergency_accounts: emergency_accounts,
        fire_bridge_balance: money(bridge_balance),
        fire_later_balance: money(later_balance),
        review_prompts: prompts,
        fx_unavailable: fx_unavailable
      )
    end

    private
      attr_reader :user, :profile, :family

      def accounts
        @accounts ||= user.finance_accounts.visible.includes(:accountable).to_a
      end

      def emergency_accounts
        explicit_ids = profile.emergency_account_ids.to_set
        if profile.emergency_account_ids_overridden?
          return accounts.select { |account| explicit_ids.include?(account.id) && emergency_account?(account) }
        end

        accounts.select { |account| emergency_account?(account) }
      end

      def fire_role_for(account)
        profile.fire_role_overrides[account.id]
      end

      def singapore_context?
        profile.singapore?
      end

      def cpf_account?(account)
        account.accountable_type == "Investment" && account.subtype.to_s.start_with?("cpf_")
      end

      def srs_account?(account)
        account.name.to_s.match?(/\bsrs\b/i)
      end

      def srs_prompt_needed?(later_accounts)
        return false unless profile.singapore?
        return false if profile.prompt_skipped?("srs")

        srs_accounts = accounts.select { |account| srs_account?(account) }
        srs_accounts.any? && (srs_accounts - later_accounts).any?
      end

      def asset_account?(account)
        account.classification == "asset"
      end

      def default_bridge_account?(account)
        asset_account?(account) &&
          %w[Depository Investment Crypto].include?(account.accountable_type) &&
          !locked_retirement_investment?(account)
      end

      def emergency_account?(account)
        asset_account?(account) && account.accountable_type == "Depository"
      end

      def locked_retirement_investment?(account)
        account.accountable_type == "Investment" &&
          LOCKED_RETIREMENT_INVESTMENT_SUBTYPES.include?(account.subtype.to_s)
      end

      def sum_balances(selected_accounts)
        fx_unavailable = false
        total = selected_accounts.sum do |account|
          converted_balance(account)
        rescue Money::ConversionError
          fx_unavailable = true
          0.to_d
        end

        [ total, fx_unavailable ]
      end

      def converted_balance(account)
        return account.balance.to_d if account.currency == family.currency

        account.balance_money.exchange_to(family.currency).amount
      end

      def money(amount)
        Money.new(amount, family.currency)
      end
  end
end
