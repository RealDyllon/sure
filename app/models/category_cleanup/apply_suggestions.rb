module CategoryCleanup
  class ApplySuggestions
    def self.call(run:, job_id: nil)
      new(run: run, job_id: job_id).call
    end

    def initialize(run:, job_id: nil)
      @run = run
      @job_id = job_id
    end

    def call
      selected_scope = ordered_selected_suggestions
      total = selected_scope.size
      processed = 0

      return unless mark_unselected_unchanged!

      selected_scope.each do |suggestion|
        return unless run.reload.processing_progress_job_matches?(job_id)

        run.with_lock do
          run.reload
          return unless run.processing_progress_job_matches?(job_id)

          suggestion.apply!
        end

        processed += 1
        run.update_processing_progress!(
          phase: :applying,
          message: "Applying reviewed category cleanup",
          current: processed,
          total: total,
          guard_job_id: job_id
        )
      end

      run.with_lock do
        run.reload
        return unless run.processing_progress_job_matches?(job_id)

        run.refresh_counts!
        run.update!(status: :complete, error: nil, finished_at: Time.current)
      end
      run.finish_processing_progress!(message: "Category cleanup complete", guard_job_id: job_id)
    rescue => error
      sanitized = AutoCategorization::ErrorSanitizer.call(error)
      if run.fail_processing_progress!(message: sanitized, guard_job_id: job_id)
        run.update!(
          status: :failed,
          error: sanitized,
          metadata: run.metadata.to_h.merge("failed_phase" => "applying"),
          finished_at: Time.current
        )
      end
      raise
    end

    private
      attr_reader :run, :job_id

      def ordered_selected_suggestions
        suggestions = run.suggestions.selected.actionable.order(:created_at).to_a
        merge_suggestions = suggestions.select(&:action_merge?)
        non_merge_suggestions = suggestions.reject(&:action_merge?)

        return non_merge_suggestions if merge_suggestions.none?
        return merge_suggestions + non_merge_suggestions if merge_suggestions.one?

        merge_by_source = merge_suggestions.index_by { |suggestion| suggestion.source_category_id.to_s }
        merge_by_target = merge_suggestions.group_by { |suggestion| suggestion.target_category_id.to_s }

        in_degree = merge_suggestions.each_with_object(Hash.new(0)) do |suggestion, degree|
          degree[suggestion] = (merge_by_target[suggestion.source_category_id.to_s] || []).size
        end

        queue = merge_suggestions.select { |suggestion| in_degree[suggestion].zero? }
        sorted = []

        until queue.empty?
          suggestion = queue.shift
          sorted << suggestion

          dependents = Array(merge_by_source[suggestion.target_category_id.to_s]).compact
          dependents.each do |dependent|
            in_degree[dependent] -= 1
            queue << dependent if in_degree[dependent].zero?
          end
        end

        if sorted.size != merge_suggestions.size
          raise CategoryCleanup::MergeCycleError, "Selected cleanup merges form a cycle"
        end

        sorted + non_merge_suggestions
      end

      def mark_unselected_unchanged!
        run.with_lock do
          run.reload
          return false unless run.processing_progress_job_matches?(job_id)

          run.suggestions.where(selected: false).where.not(status: "unchanged").update_all(
            status: "unchanged",
            updated_at: Time.current
          )
        end

        true
      end
  end
end
