# frozen_string_literal: true

module DiscourseRepoActivity
  module DeliveryStatus
    EVENTS = %w[push workflow_run pull_request issues release].freeze
    ERRORS = %w[invalid_payload].freeze

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

    def self.clear(connection)
      Discourse.redis.del(
        state_key(connection),
        "repo-activity:unverified:#{connection.id}",
        "repo-activity:unverified:#{connection.id}:count",
        "repo-activity:status-publish:#{connection.id}",
      )
    end

    def self.state_key(connection)
      "repo-activity:verified-status:#{connection.id}"
    end

    def self.management_state(connection)
      state = JSON.parse(Discourse.redis.get(state_key(connection)) || "{}")
      unless connection.enabled?
        return state.merge("delivery_status" => "paused", "last_delivery_error" => nil)
      end
      if state.empty? && connection.last_delivery_at.nil?
        state = JSON.parse(Discourse.redis.get("repo-activity:unverified:#{connection.id}") || "{}")
      end
      if types = state.delete("received_event_types")
        state["recent_event_types"] = types
          .select { |_kind, time| Time.iso8601(time) >= 7.days.ago }
          .keys
      end
      state
    end

    def self.count(connection)
      management_state(connection).fetch("rejected_deliveries", connection.rejected_deliveries).to_i
    end

    # An unverified caller may help diagnose initial setup, but cannot change durable
    # state or make an already authenticated connection appear broken.
    def self.reject_unverified(connection, reason)
      return unless connection.enabled?
      key = "repo-activity:unverified:#{connection.id}"
      count = Discourse.redis.incr("#{key}:count")
      Discourse.redis.expire("#{key}:count", 1.hour.to_i)
      Discourse.redis.setex(
        key,
        1.hour.to_i,
        { delivery_status: reason, rejected_deliveries: count }.to_json,
      )
      notify(connection) if connection.last_delivery_at.nil?
    end

    def self.notify(connection)
      if Discourse.redis.set("repo-activity:status-publish:#{connection.id}", "1", nx: true, ex: 60)
        DB.after_commit { publish(connection.chat_channel) }
      else
        schedule_flush(connection)
      end
    end

    def self.schedule_flush(connection)
      if Discourse.redis.set("repo-activity:status-flush:#{connection.id}", "1", nx: true, ex: 120)
        Jobs.enqueue_in(1.minute, :repo_activity_delivery_status, connection_id: connection.id)
      end
    end

    def self.flush(connection)
      connection.with_lock do
        state = JSON.parse(Discourse.redis.get(state_key(connection)) || "{}")
        if state.present? &&
             (connection.status_written_at.nil? || connection.status_written_at <= 1.minute.ago)
          connection.update_columns(state.merge("status_written_at" => Time.current))
        end
      end
      notify(connection)
    end

    def self.record(connection, status, missing: nil, event_type: nil)
      raise ArgumentError if (ERRORS + %w[receiving waiting]).exclude?(status)
      connection.with_lock do
        now = Time.current
        state = JSON.parse(Discourse.redis.get(state_key(connection)) || "{}")
        missing ||= state.fetch("missing_hook_events", connection.missing_hook_events)
        hook_type = { "pipeline" => "workflow_run", "issue" => "issues", "tag" => "push" }.fetch(
          event_type,
          event_type,
        )
        missing = missing - [hook_type] if event_type
        types = state.fetch("received_event_types", connection.received_event_types)
        types = types.merge(event_type => now.iso8601) if event_type
        rejected = ERRORS.include?(status)
        state = {
          "delivery_status" => status,
          "last_delivery_at" =>
            (
              if status == "receiving"
                now.iso8601
              else
                state.fetch("last_delivery_at", connection.last_delivery_at&.iso8601)
              end
            ),
          "last_delivery_error" => rejected ? status : nil,
          "last_delivery_error_at" => rejected ? now.iso8601 : nil,
          "rejected_deliveries" => rejected ? state.fetch("rejected_deliveries", 0) + 1 : 0,
          "missing_hook_events" => missing,
          "received_event_types" => types,
        }
        Discourse.redis.setex(state_key(connection), 14.days.to_i, state.to_json)
        unless rejected
          Discourse.redis.del(
            "repo-activity:unverified:#{connection.id}",
            "repo-activity:unverified:#{connection.id}:count",
          )
        end
        if connection.status_written_at.nil? || connection.status_written_at <= 1.minute.ago
          connection.update_columns(state.merge("status_written_at" => now))
        else
          schedule_flush(connection)
        end
      end
      notify(connection)
    end
  end
end
