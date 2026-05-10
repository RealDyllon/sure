class AutoCategorizationRunsController < ApplicationController
  layout "wizard", only: :show

  before_action :set_run, except: :create
  before_action :set_categories, only: :show

  def create
    run = AutoCategorization::RunCreator.call(family: Current.family, user: Current.user)
    redirect_to auto_categorization_run_path(run)
  rescue AutoCategorization::RunCreator::MissingProviderError
    redirect_to categories_path, alert: "AI configuration is required before auto-categorizing transactions."
  end

  def show
    @category_suggestions = @run.category_suggestions.order(:created_at)
    @suggestions_scope = filtered_suggestions_scope
    @per_page = safe_per_page
    @pagy, @suggestions = pagy(@suggestions_scope, limit: @per_page) if @run.suggestions.exists?
    @suggestions ||= []
  end

  def retry
    unless provider_configured?
      redirect_to auto_categorization_run_path(@run), alert: "AI configuration is required before retrying."
      return
    end

    queued = if @run.reviewing_categories?
      @run.queue_generation!
    else
      @run.queue_retry! || @run.queue_generation!
    end

    redirect_to auto_categorization_run_path(@run), notice: queued ? "Retry queued." : "This run cannot be retried right now."
  end

  def update_category_suggestion
    suggestion = @run.category_suggestions.find(params[:category_suggestion_id])
    suggestion.update!(category_suggestion_params)

    redirect_to auto_categorization_run_path(@run, review_query_params)
  end

  def create_category_suggestion
    @run.category_suggestions.create!(category_suggestion_params.merge(selected: true))
    @run.update!(status: :reviewing_categories) if @run.suggesting_categories?

    redirect_to auto_categorization_run_path(@run), notice: "Category suggestion added."
  end

  def bootstrap_categories
    Current.family.categories.bootstrap!
    @run.queue_generation!

    redirect_to auto_categorization_run_path(@run), notice: "Default categories created. Transaction suggestions are being generated."
  end

  def create_categories
    queued = @run.queue_category_creation!

    redirect_to auto_categorization_run_path(@run), notice: queued ? "Category creation queued." : "Select at least one valid category first."
  end

  def update_suggestion
    unless @run.reviewing_transactions?
      redirect_to auto_categorization_run_path(@run, review_query_params), alert: "This run is no longer editable."
      return
    end

    suggestion = @run.suggestions.find(params[:suggestion_id])
    selected_category = selected_category_from_params

    suggestion.update!(
      selected: ActiveModel::Type::Boolean.new.cast(params[:suggestion_selected].presence || params[:selected]),
      selected_category: selected_category,
      selected_category_name: selected_category&.name
    )

    @run.refresh_counts!
    redirect_to auto_categorization_run_path(@run, review_query_params)
  end

  def apply
    queued = @run.queue_apply!

    redirect_to auto_categorization_run_path(@run, review_query_params),
                notice: queued ? "Apply queued." : "Select at least one valid suggestion first."
  end

  private
    def set_run
      @run = Current.user.auto_categorization_runs.find(params[:id])
    end

    def set_categories
      @categories = Current.family.categories.alphabetically
    end

    def provider_configured?
      Provider::Registry.default_llm_provider.present?
    end

    def filtered_suggestions_scope
      scope = @run.suggestions
                  .includes(:suggested_category, :selected_category, run_transaction: [ :entry, :live_transaction, :account ])
                  .order(created_at: :asc)

      q = params[:q].presence || params[:search].presence
      if q.present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"
        scope = scope.joins(:run_transaction)
                     .where("auto_categorization_run_transactions.snapshot ->> 'description' ILIKE ? OR auto_categorization_run_transactions.snapshot ->> 'name' ILIKE ?", pattern, pattern)
      end

      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(selected: ActiveModel::Type::Boolean.new.cast(params[:selected])) if params[:selected].present?
      scope = scope.where(selected_category_id: params[:category_id]) if params[:category_id].present?
      scope
    end

    def selected_category_from_params
      return nil if params[:selected_category_id].blank?

      Current.family.categories.find(params[:selected_category_id])
    end

    def category_suggestion_params
      params.require(:auto_categorization_category_suggestion)
            .permit(:name, :parent_name, :color, :lucide_icon, :rationale, :selected)
    end

    def review_query_params
      request.query_parameters
             .slice("q", "search", "status", "selected", "category_id", "page", "per_page")
             .presence || params.permit(:q, :search, :status, :category_id, :page, :per_page).to_h
    end
end
