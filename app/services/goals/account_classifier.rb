module Goals
  class AccountClassifier
    Result = Data.define(
      :fire_bridge_accounts,
      :fire_later_accounts,
      :fire_excluded_accounts,
      :emergency_accounts,
      :fire_bridge_balance,
      :fire_later_balance,
      :review_prompts
    )

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
          bridge_accounts << account
        when "later"
          later_accounts << account
        when "excluded"
          excluded_accounts << account
        else
          if cpf_account?(account) && singapore_context?
            later_accounts << account
          elsif asset_account?(account)
            bridge_accounts << account
          else
            excluded_accounts << account
          end
        end
      end

      prompts << :srs_mapping if srs_prompt_needed?(later_accounts)

      Result.new(
        fire_bridge_accounts: bridge_accounts,
        fire_later_accounts: later_accounts,
        fire_excluded_accounts: excluded_accounts,
        emergency_accounts: emergency_accounts,
        fire_bridge_balance: money(sum_balances(bridge_accounts)),
        fire_later_balance: money(sum_balances(later_accounts)),
        review_prompts: prompts
      )
    end

    private
      attr_reader :user, :profile, :family

      def accounts
        @accounts ||= user.finance_accounts.visible.includes(:accountable).to_a
      end

      def emergency_accounts
        explicit_ids = profile.emergency_account_ids.to_set
        return accounts.select { |account| explicit_ids.include?(account.id) } if explicit_ids.any?

        accounts.select { |account| account.accountable_type == "Depository" && asset_account?(account) }
      end

      def fire_role_for(account)
        profile.fire_role_overrides[account.id]
      end

      def singapore_context?
        profile.singapore? || accounts.any? { |account| cpf_account?(account) }
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

      def sum_balances(selected_accounts)
        selected_accounts.sum { |account| converted_balance(account) }
      end

      def converted_balance(account)
        return account.balance.to_d if account.currency == family.currency

        account.balance_money.exchange_to(family.currency).amount
      rescue Money::ConversionError
        0.to_d
      end

      def money(amount)
        Money.new(amount, family.currency)
      end
  end
end
