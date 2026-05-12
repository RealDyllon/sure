module AutoCategorizationTestHelper
  class FakeLlmProvider
    attr_reader :suggest_category_calls, :auto_categorize_calls

    def initialize(category_suggestions: [], categorizations: [], on_suggest_categories: nil, on_auto_categorize: nil)
      @category_suggestions = category_suggestions
      @categorizations = categorizations
      @on_suggest_categories = on_suggest_categories
      @on_auto_categorize = on_auto_categorize
      @suggest_category_calls = []
      @auto_categorize_calls = []
    end

    def provider_name
      "Fake LLM"
    end

    def suggest_categories(transactions:, **_options)
      @suggest_category_calls << transactions
      @on_suggest_categories&.call
      Provider::Response.new(success?: true, data: @category_suggestions, error: nil)
    end

    def auto_categorize(transactions:, user_categories:, **_options)
      @auto_categorize_calls << { transactions: transactions, user_categories: user_categories }
      @on_auto_categorize&.call
      Provider::Response.new(success?: true, data: @categorizations, error: nil)
    end
  end

  def stub_default_llm_provider(provider = FakeLlmProvider.new)
    Provider::Registry.stubs(:default_llm_provider).returns(provider)
    Provider::Registry.stubs(:default_llm_model).returns("test-model")
    provider
  end

  def create_auto_categorization_run(family: users(:family_admin).family, user: users(:family_admin), status: :draft)
    AutoCategorizationRun.create!(
      family: family,
      user: user,
      status: status,
      provider_name: "Fake LLM",
      model: "test-model",
      started_at: Time.current
    )
  end

  def create_run_transaction(run, entry)
    run.run_transactions.create!(
      entry: entry,
      live_transaction: entry.transaction,
      account: entry.account,
      captured_at: Time.current,
      snapshot: {
        "date" => entry.date.iso8601,
        "name" => entry.name,
        "description" => entry.name,
        "amount" => entry.amount.abs.to_s,
        "currency" => entry.currency,
        "classification" => entry.classification,
        "transaction_kind" => entry.transaction.kind
      }
    )
  end
end
