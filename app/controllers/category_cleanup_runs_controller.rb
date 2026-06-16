class CategoryCleanupRunsController < ApplicationController
  layout "wizard", only: :show

  before_action :set_run, except: :create
  before_action :set_categories, only: %i[show update_suggestion]

  def create
    run = CategoryCleanup::RunCreator.call(family: Current.family, user: Current.user)
    redirect_to category_cleanup_run_path(run)
  rescue CategoryCleanup::RunCreator::MissingProviderError
    redirect_to categories_path, alert: "AI configuration is required before organizing categories."
  end

  def show
    @suggestions_scope = filtered_suggestions_scope
    @per_page = safe_per_page
    @pagy, @suggestions = pagy(@suggestions_scope, limit: @per_page) if @run.suggestions.exists?
    @suggestions ||= []
  end

  def retry
    if retry_requires_provider? && !provider_configured?
      redirect_to category_cleanup_run_path(@run), alert: "AI configuration is required before retrying."
      return
    end

    queued = @run.queue_retry!
    redirect_to category_cleanup_run_path(@run), notice: queued ? "Retry queued." : "This cleanup run cannot be retried right now."
  end

  def update_suggestion
    unless @run.reviewing?
      redirect_to category_cleanup_run_path(@run, review_query_params), alert: "This run is no longer editable."
      return
    end

    suggestion = @run.suggestions.find(params[:suggestion_id])
    suggestion.assign_attributes(suggestion_params_for_update(suggestion))
    suggestion.error = suggestion.current_review_error
    suggestion.status = suggestion.error.present? ? :needs_review : :suggested
    suggestion.selected = false if suggestion.error.present? || suggestion.action_keep?
    suggestion.save!
    @run.refresh_counts!

    redirect_to category_cleanup_run_path(@run, review_query_params)
  end

  def apply
    queued = @run.queue_apply!

    redirect_to category_cleanup_run_path(@run, review_query_params),
                notice: queued ? "Apply queued." : "Select at least one valid cleanup suggestion first."
  end

  private
    def set_run
      @run = Current.user.category_cleanup_runs.find(params[:id])
    end

    def set_categories
      @categories = Current.family.categories.alphabetically_by_hierarchy
      @root_categories = Current.family.categories.roots.alphabetically
    end

    def provider_configured?
      Provider::Registry.default_llm_provider.present?
    end

    def retry_requires_provider?
      progress_phase = @run.processing_progress.to_h["phase"]
      failed_phase = @run.metadata.to_h["failed_phase"]

      progress_phase != "applying" && failed_phase != "applying"
    end

    def filtered_suggestions_scope
      scope = @run.suggestions
                  .includes(:source_category, :target_category, :parent_category)
                  .order(created_at: :asc)

      q = params[:q].presence || params[:search].presence
      if q.present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"
        scope = scope.where(
          "source_category_name ILIKE :pattern OR target_category_name ILIKE :pattern OR parent_category_name ILIKE :pattern OR new_name ILIKE :pattern OR rationale ILIKE :pattern",
          pattern: pattern
        )
      end

      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(suggested_action: params[:filter_action]) if params[:filter_action].present?
      scope = scope.where(selected: ActiveModel::Type::Boolean.new.cast(params[:selected])) if params[:selected].present?
      scope = scope.where(source_category_id: params[:category_id]) if params[:category_id].present?
      scope
    end

    def suggestion_params_for_update(suggestion)
      action = params[:suggested_action].presence || params.dig(:category_cleanup_suggestion, :suggested_action)
      action = "keep" unless CategoryCleanupSuggestion.suggested_actions.key?(action)

      attrs = {
        suggested_action: action,
        selected: ActiveModel::Type::Boolean.new.cast(params[:suggestion_selected].presence || params.dig(:category_cleanup_suggestion, :selected))
      }

      case action
      when "merge"
        attrs.merge!(
          target_category: category_from_param(:target_category_id),
          parent_category: nil,
          new_name: nil,
          metadata: reparent_intent_metadata(suggestion, nil, reparent: false)
        )
      when "rename"
        attrs.merge!(
          target_category: nil,
          parent_category: nil,
          new_name: params[:new_name].to_s.squish.presence,
          metadata: reparent_intent_metadata(suggestion, nil, reparent: false)
        )
      when "reparent"
        parent_category_id = category_id_from_param(:parent_category_id)
        attrs.merge!(
          target_category: nil,
          parent_category: category_from_id(parent_category_id),
          new_name: nil,
          metadata: reparent_intent_metadata(suggestion, parent_category_id, reparent: true)
        )
      else
        attrs.merge!(
          target_category: nil,
          parent_category: nil,
          new_name: nil,
          metadata: reparent_intent_metadata(suggestion, nil, reparent: false),
          selected: false
        )
      end

      attrs
    end

    def category_from_param(key)
      id = category_id_from_param(key)
      return if id.blank?

      category_from_id(id)
    end

    def category_from_id(id)
      return if id.blank?

      Current.family.categories.find(id)
    end

    def category_id_from_param(key)
      params[key].presence || params.dig(:category_cleanup_suggestion, key)
    end

    def reparent_intent_metadata(suggestion, parent_category_id, reparent:)
      suggestion.metadata.to_h.merge(
        "reparent_intended_root" => reparent && parent_category_id.blank?,
        "reparent_intended_parent_category_id" => parent_category_id.presence
      )
    end

    def review_query_params
      request.query_parameters
             .slice("q", "search", "status", "selected", "category_id", "filter_action", "page", "per_page")
             .presence || params.permit(:q, :search, :status, :selected, :category_id, :filter_action, :page, :per_page).to_h
    end
end
