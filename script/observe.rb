# frozen_string_literal: true

module RepoActivitySimulationObserver
  def publish(channel, *args, **kwargs)
    if channel.start_with?("/repo-activity/")
      Discourse.redis.hincrby("ra-sim:publishes", channel, 1)
    end
    super
  end
end

# Loaded only by the disposable simulation runtime, never by plugin.rb.
Rails.application.config.after_initialize do
  %i[RepoActivityAnnounce RepoActivityPublish].each do |name|
    Jobs.const_get(name).prepend(
      Module.new do
        define_method(:execute) do |args|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            super(args)
          rescue StandardError => error
            Discourse.redis.rpush("ra-sim:errors", error.class.name)
            raise
          ensure
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            Discourse.redis.rpush("ra-sim:jobs:#{name}", elapsed)
          end
        end
      end,
    )
  end
  MessageBus.singleton_class.prepend(RepoActivitySimulationObserver)
end
