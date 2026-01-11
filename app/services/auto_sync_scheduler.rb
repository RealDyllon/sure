# app/services/auto_sync_scheduler.rb
class AutoSyncScheduler
  JOB_NAME = "sync_all_accounts"

  def self.sync!
    Rails.logger.info("[AutoSyncScheduler] auto_sync_enabled=#{Setting.auto_sync_enabled}, time=#{Setting.auto_sync_time}")
    if Setting.auto_sync_enabled?
      upsert_job
    else
      remove_job
    end
  end

  def self.upsert_job
    time = Setting.auto_sync_time || "02:22"

    hour, minute = time.split(":").map(&:to_i)
    cron = "#{minute} #{hour} * * *"

    Sidekiq::Cron::Job.create(
      name: JOB_NAME,
      cron: cron,
      class: "SyncAllJob",
      queue: "scheduled",
      description: "Syncs all accounts for all families"
    )
  end

  def self.remove_job
    if (job = Sidekiq::Cron::Job.find(JOB_NAME))
      job.destroy
    end
  end
end
