module CategoryCleanup
  class RunCreator
    MissingProviderError = Class.new(StandardError)

    def self.call(family:, user:)
      new(family: family, user: user).call
    end

    def initialize(family:, user:)
      @family = family
      @user = user
    end

    def call
      provider = Provider::Registry.default_llm_provider
      raise MissingProviderError, "AI configuration is required" unless provider

      run = CategoryCleanupRun.create!(
        family: family,
        user: user,
        status: :draft,
        provider_name: provider.provider_name,
        model: Provider::Registry.default_llm_model,
        metadata: { "categories_snapshot" => category_snapshot },
        started_at: Time.current
      )

      if run.category_snapshot.none?
        run.update!(status: :empty, finished_at: Time.current)
        run.finish_processing_progress!(message: "No categories available to organize")
      else
        run.queue_generation!
      end

      run
    end

    private
      attr_reader :family, :user

      def category_snapshot
        categories = family.categories.includes(:parent, :subcategories).alphabetically_by_hierarchy.to_a
        direct_transaction_counts = family.transactions.where(category_id: categories.map(&:id)).group(:category_id).count

        categories.map do |category|
          {
            "id" => category.id,
            "name" => category.name,
            "parent_id" => category.parent_id,
            "parent_name" => category.parent&.name,
            "path" => category.name_with_parent,
            "is_parent" => category.subcategories.any?,
            "is_subcategory" => category.subcategory?,
            "direct_transaction_count" => direct_transaction_counts[category.id] || 0,
            "child_count" => category.subcategories.size,
            "color" => category.color,
            "lucide_icon" => category.lucide_icon
          }
        end
      end
  end
end
