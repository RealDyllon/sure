# Fork metadata is deliberately independent of Sure.version and upstream builds.
class ForkRelease
  class << self
    def version
      content = Rails.root.join(".fork-version").read.strip
      Semver.new(content) if content.present?
    rescue Errno::ENOENT, ArgumentError
      nil
    end

    def tag
      "fork-v#{version}" if version
    end

    def repository
      value = ENV.fetch("FORK_GITHUB_REPOSITORY", "RealDyllon/sure")
      raise ArgumentError, "invalid fork repository" unless value.match?(/\A[\w.-]+\/[\w.-]+\z/)

      value
    end
  end
end
