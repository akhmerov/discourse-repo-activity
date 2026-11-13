# frozen_string_literal: true

module DiscourseRepoActivity
  module DeliveryStatus
    EVENTS = %w[push workflow_run pull_request issues release].freeze
    ERRORS = %w[wrong_secret missing_signature invalid_payload ignored_event archived].freeze

    def self.watch(channel, user)
      key = "repo-activity:managers:#{channel.id}"
      Discourse.redis.zadd(key, Time.now.to_i, user.id)
      Discourse.redis.zremrangebyscore(key, "-inf", Time.now.to_i - 300)
      Discourse.redis.expire(key, 600)
    end

    def self.publish(channel)
      ids =
        Discourse.redis.zrangebyscore(
          "repo-activity:managers:#{channel.id}",
          Time.now.to_i - 300,
          "+inf",
        )
      managers =
        User
          .where(id: ids)
          .select { |user| DiscourseRepoActivity.can_manage?(channel, user) }
          .map(&:id)
      return if managers.empty?
      MessageBus.publish(
        "/repo-activity/management/#{channel.id}",
        { refresh: true },
        user_ids: managers,
      )
    end

    def self.count(connection)
      (
        Discourse.redis.get("repo-activity:rejected:#{connection.id}") ||
          connection.rejected_deliveries
      ).to_i
    end

    def self.record(connection, status, missing: nil, event_type: nil)
      raise ArgumentError if (ERRORS + %w[receiving waiting]).exclude?(status)
      rejected = ERRORS.include?(status)
      key = "repo-activity:rejected:#{connection.id}"
      Discourse.redis.set(key, connection.rejected_deliveries, nx: true)
      count = rejected ? Discourse.redis.incr(key) : 0
      Discourse.redis.set(key, 0) unless rejected
      Discourse.redis.expire(key, 14.days.to_i)
      changed = false
      connection.with_lock do
        now = Time.current
        fresh_type = event_type && !connection.received_event_types.key?(event_type)
        if fresh_type || connection.delivery_status != status ||
             missing && connection.missing_hook_events != missing ||
             connection.status_written_at.nil? || connection.status_written_at <= 1.minute.ago
          attributes = {
            delivery_status: status,
            status_written_at: now,
            rejected_deliveries: count,
          }
          attributes[:last_delivery_at] = now if status == "receiving"
          if rejected
            attributes[:last_delivery_error] = status
            attributes[:last_delivery_error_at] = now
          end
          attributes[:missing_hook_events] = missing if missing
          if %w[push pipeline pull_request issue release tag].include?(event_type)
            attributes[:received_event_types] = connection.received_event_types.merge(
              event_type => now.iso8601,
            )
          end
          connection.update_columns(attributes)
          changed = true
        end
      end
      DB.after_commit { publish(connection.chat_channel) } if changed
    end
  end
end
