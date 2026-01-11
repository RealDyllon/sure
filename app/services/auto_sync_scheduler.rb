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
    time_str = Setting.auto_sync_time || "02:22"
    hour, minute = time_str.split(":").map(&:to_i)

    local_time = Time.zone.now.change(hour: hour, min: minute, sec: 0)
    utc_time = local_time.utc

    cron = "#{utc_time.min} #{utc_time.hour} * * *"

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
