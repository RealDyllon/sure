module AutoCategorization
  class GenerateSuggestions
    def self.call(run:, job_id: nil)
      new(run:, job_id:).call
    end

    def initialize(run:, job_id: nil)
      @run = run
      @job_id = job_id
    end

    def call
      provider = Provider::Registry.default_llm_provider
      raise RunCreator::MissingProviderError, "AI configuration is required" unless provider

      if run.family.categories.none?
        generate_category_suggestions(provider)
      else
        generate_transaction_suggestions(provider)
      end
    rescue => error
      fail_run!(error)
      raise
    end

    private
      attr_reader :run, :job_id

      def generate_category_suggestions(provider)
        return unless run.processing_progress_job_matches?(job_id)

        response = provider.suggest_categories(
          transactions: run.run_transactions.map(&:to_llm_input),
          model: run.model,
          family: run.family
        )

        raise response.error unless response.success?

        normalized = StarterCategoryNormalizer.call(categories: response.data, family: run.family)

        run.with_lock do
          run.reload
          return unless run.processing_progress_job_matches?(job_id)

          normalized.each do |attrs|
            suggestion = run.category_suggestions.find_or_initialize_by(normalized_name: attrs[:normalized_name])
            suggestion.assign_attributes(attrs)
            suggestion.save!
          end

          run.update!(
            status: :reviewing_categories,
            category_suggestions_count: run.category_suggestions.count,
            selected_count: run.category_suggestions.selected.count,
            error: nil
          )
        end
        run.finish_processing_progress!(message: "Starter categories ready for review", guard_job_id: job_id)
      end

      def generate_transaction_suggestions(provider)
        if run.family.categories.none?
          raise "Create at least one category before generating transaction suggestions"
        end

        categories_input = user_categories_input
        return unless ensure_pending_suggestion_rows!

        generation_scope = run.run_transactions.where.not(status: :generated).order(:created_at)
        total = generation_scope.count
        processed = 0

        generation_scope.find_in_batches(batch_size: AutoCategorizationRun::GENERATION_BATCH_SIZE) do |batch|
          return unless run.reload.processing_progress_job_matches?(job_id)

          response = provider.auto_categorize(
            transactions: batch.map(&:to_llm_input),
            user_categories: categories_input,
            model: run.model,
            family: run.family
          )

          raise response.error unless response.success?

          run.with_lock do
            run.reload
            return unless run.processing_progress_job_matches?(job_id)

            persist_transaction_batch!(batch, response.data, categories_input)
          end

          processed += batch.size
          run.update_processing_progress!(
            phase: :suggesting_transactions,
            message: "Generating transaction suggestions",
            current: processed,
            total: total,
            guard_job_id: job_id
          )
        end

        run.with_lock do
          run.reload
          return unless run.processing_progress_job_matches?(job_id)

          run.update!(status: :reviewing_transactions, error: nil)
          run.refresh_counts!
        end
        run.finish_processing_progress!(message: "Transaction suggestions ready for review", guard_job_id: job_id)
      end

      def ensure_pending_suggestion_rows!
        run.with_lock do
          run.reload
          return false unless run.processing_progress_job_matches?(job_id)

          run.run_transactions.where.not(status: :generated).find_each do |run_transaction|
            run.suggestions.find_or_create_by!(run_transaction: run_transaction) do |suggestion|
              suggestion.status = :pending_generation
            end
          end
        end

        true
      end

      def persist_transaction_batch!(batch, provider_rows, categories_input)
        rows_by_id = Array(provider_rows).index_by { |row| row.transaction_id.to_s }

        batch.each do |run_transaction|
          provider_row = rows_by_id[run_transaction.id.to_s]
          category = category_for(provider_row&.category_name, categories_input)
          suggestion = run.suggestions.find_or_initialize_by(run_transaction: run_transaction)

          suggestion.assign_attributes(
            suggested_category: category,
            selected_category: category,
            suggested_category_name: provider_row&.category_name,
            selected_category_name: category&.name,
            selected: category.present?,
            status: category.present? ? :suggested : :needs_review,
            reason: category.present? ? nil : "No matching category suggestion",
            error: nil
          )
          suggestion.save!
          run_transaction.update!(status: :generated)
        end
      end

      def category_for(category_name, categories_input)
        return if category_name.blank?

        category_data = categories_input.find { |category| category[:name].to_s.casecmp?(category_name.to_s) }
        return unless category_data

        run.family.categories.find_by(id: category_data[:id])
      end

      def user_categories_input
        run.family.categories.alphabetically.map do |category|
          {
            id: category.id,
            name: category.name,
            is_subcategory: category.subcategory?,
            parent_id: category.parent_id
          }
        end
      end

      def fail_run!(error)
        sanitized = ErrorSanitizer.call(error)
        if run.fail_processing_progress!(message: sanitized, guard_job_id: job_id)
          run.update!(
            status: :failed,
            error: sanitized,
            metadata: run.metadata.to_h.merge("failed_phase" => run.processing_progress.to_h["phase"]),
            finished_at: Time.current
          )
        end
      end
  end
end
