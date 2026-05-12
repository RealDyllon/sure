module AutoCategorization
  class EligibilityQuery
    def initialize(family:, user:)
      @family = family
      @user = user
    end

    def entries
      base_scope
        .uncategorized_transactions
        .excluding_split_parents
        .merge(Transaction.enrichable(:category_id))
        .preload(:account, entryable: :merchant)
        .order(date: :desc, created_at: :desc)
    end

    private
      attr_reader :family, :user

      def base_scope
        scope = family.entries.joins(:account)
        return scope unless user

        scope.merge(Account.annotatable_by(user))
      end
  end
end
