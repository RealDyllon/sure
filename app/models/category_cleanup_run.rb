class CategoryCleanupRun < ApplicationRecord
  PROCESSING_PROGRESS_STALE_AFTER = 5.minutes
  MAX_GENERATION_RETRIES = 1
  MAX_APPLY_RETRIES = 1

  belongs_to :family
  belongs_to :user

  has_many :suggestions,
           class_name: "CategoryCleanupSuggestion",
           dependent: :destroy,
           inverse_of: :run

  enum :status, {
    draft: "draft",
    generating: "generating",
    reviewing: "reviewing",
    applying: "applying",
    complete: "complete",
    empty: "empty",
    failed: "failed"
  }, validate: true, default: "draft"

  scope :ordered, -> { order(created_at: :desc) }
  scope :active, -> { where(status: %w[draft generating reviewing applying failed]) }

  def category_snapshot
    metadata.to_h["categories_snapshot"].to_a
  end

  def queue_generation!(allow_retry: false)
    job = CategoryCleanupGenerateJob.new(self)

    with_lock do
      reload
      return false if applying? || complete?

      enqueue_generation_job!(job, allow_retry: allow_retry)
    end

    job.enqueue
    true
  end

  def queue_apply!(allow_retry: false)
    job = CategoryCleanupApplyJob.new(self)

    with_lock do
      reload
      return false unless reviewing? ||
      (failed? && metadata.to_h["failed_phase"] == "applying") ||
      (allow_retry && applying?)
      return false unless suggestions.selected.actionable.exists?

      enqueue_apply_job!(job, allow_retry: allow_retry)
    end

    job.enqueue
    true
  end

  def update_processing_progress!(phase:, message:, current: nil, total: nil, job_id: nil, retry_count: nil, guard_job_id: nil)
    with_lock do
      reload
      now = Time.current.iso8601
      progress = processing_progress.to_h.deep_stringify_keys
      return false if guard_job_id.present? && progress["job_id"].present? && progress["job_id"] != guard_job_id

      progress["phase"] = phase.to_s
      progress["message"] = message.to_s
      progress["current"] = current unless current.nil?
      progress["total"] = total unless total.nil?
      progress["started_at"] = now if progress["started_at"].blank?
      progress["last_updated_at"] = now
      progress["finished_at"] = nil
      progress["job_id"] = job_id if job_id.present?
      progress["retry_count"] = retry_count unless retry_count.nil?

      percent = processing_progress_percent_for(progress["current"], progress["total"])
      progress["percent"] = percent unless percent.nil?

      update!(processing_progress: progress)
    end
    true
  end

  def finish_processing_progress!(message:, guard_job_id: nil)
    with_lock do
      reload
      now = Time.current.iso8601
      progress = processing_progress.to_h.deep_stringify_keys
      return false if guard_job_id.present? && progress["job_id"].present? && progress["job_id"] != guard_job_id

      total = progress["total"]
      progress["phase"] = "complete"
      progress["message"] = message.to_s
      progress["current"] = total if total.present?
      progress["percent"] = 100
      progress["last_updated_at"] = now
      progress["finished_at"] = now

      update!(processing_progress: progress)
    end
    true
  end

  def fail_processing_progress!(message:, guard_job_id: nil)
    sanitized = AutoCategorization::ErrorSanitizer.call(message)

    with_lock do
      reload
      now = Time.current.iso8601
      progress = processing_progress.to_h.deep_stringify_keys
      return false if guard_job_id.present? && progress["job_id"].present? && progress["job_id"] != guard_job_id

      progress["phase"] = "failed"
      progress["message"] = sanitized
      progress["last_updated_at"] = now
      progress["finished_at"] = now

      update!(processing_progress: progress)
    end
    true
  end

  def processing_progress_job_matches?(job_id)
    return true if job_id.blank?

    progress_job_id = processing_progress.to_h["job_id"]
    progress_job_id.blank? || progress_job_id == job_id
  end

  def processing_progress_percent
    processing_progress&.dig("percent")
  end

  def processing_progress_stale?
    return false unless generating? || applying?

    last_updated_at = processing_progress&.dig("last_updated_at")
    return updated_at < PROCESSING_PROGRESS_STALE_AFTER.ago if last_updated_at.blank?

    parsed_last_updated_at = Time.zone.parse(last_updated_at.to_s)
    parsed_last_updated_at.blank? || parsed_last_updated_at < PROCESSING_PROGRESS_STALE_AFTER.ago
  rescue ArgumentError, TypeError
    true
  end

  def retryable_processing_stall?
    processing_progress_stale? && retry_count_for_current_phase < retry_limit_for_current_phase
  end

  def retryable_processing?
    (failed? || retryable_processing_stall?) && retry_count_for_current_phase < retry_limit_for_current_phase
  end

  def queue_retry!(message: "Retry queued")
    return false unless retryable_processing?

    job = nil

    with_lock do
      reload
      return false unless retryable_processing?

      progress = processing_progress.to_h.deep_stringify_keys
      retry_count = progress["retry_count"].to_i + 1
      update!(
        processing_progress: progress.merge(
          "retry_count" => retry_count,
          "message" => message,
          "job_id" => nil,
          "last_updated_at" => Time.current.iso8601
        )
      )

      if progress["phase"] == "applying" || metadata.to_h["failed_phase"] == "applying"
        job = CategoryCleanupApplyJob.new(self)
        enqueue_apply_job!(job, allow_retry: true)
      else
        job = CategoryCleanupGenerateJob.new(self)
        enqueue_generation_job!(job, allow_retry: true)
      end
    end

    job.enqueue
    true
  end

  def refresh_counts!
    update!(
      suggestions_count: suggestions.count,
      selected_count: suggestions.selected.count,
      applied_count: suggestions.applied.count,
      skipped_count: suggestions.skipped.count,
      unchanged_count: suggestions.unchanged.count
    )
  end

  private
    def enqueue_generation_job!(job, allow_retry:)
      update!(
        status: :generating,
        error: nil,
        started_at: started_at || Time.current,
        finished_at: nil
      )
      update_processing_progress!(
        phase: :generating,
        message: "Generating category cleanup suggestions",
        current: 0,
        total: category_snapshot.size,
        job_id: job.job_id,
        retry_count: allow_retry ? processing_progress.to_h["retry_count"].to_i : 0
      )
    end

    def enqueue_apply_job!(job, allow_retry:)
      update!(status: :applying, error: nil)
      update_processing_progress!(
        phase: :applying,
        message: "Applying reviewed category cleanup",
        current: 0,
        total: suggestions.selected.actionable.count,
        job_id: job.job_id,
        retry_count: allow_retry ? processing_progress.to_h["retry_count"].to_i : 0
      )
    end

    def processing_progress_percent_for(current, total)
      return unless current && total

      total = total.to_i
      return unless total.positive?

      current = current.to_i
      ((current.to_f / total) * 100).round.clamp(0, 100)
    end

    def retry_count_for_current_phase
      processing_progress.to_h["retry_count"].to_i
    end

    def retry_limit_for_current_phase
      applying? || metadata.to_h["failed_phase"] == "applying" ? MAX_APPLY_RETRIES : MAX_GENERATION_RETRIES
    end
end
