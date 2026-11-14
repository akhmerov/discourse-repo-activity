# frozen_string_literal: true

module DiscourseRepoActivity
  class Event < ActiveRecord::Base
    self.table_name = "repo_activity_events"
    belongs_to :connection

    # A recovery decorates its push when that push is retained; otherwise it is
    # a standalone stream item. Counts and all pages use exactly this predicate.
    scope :visible, -> { where.not(kind: "ci").where(<<~SQL) }
        NOT (repo_activity_events.kind = 'recovery' AND EXISTS (
          SELECT 1 FROM repo_activity_events pushes
          WHERE pushes.connection_id = repo_activity_events.connection_id
            AND pushes.kind = 'push'
            AND pushes.summary->>'sha' = repo_activity_events.summary->>'sha'
        )) AND NOT (repo_activity_events.kind = 'tag' AND EXISTS (
          SELECT 1 FROM repo_activity_events releases
          WHERE releases.connection_id = repo_activity_events.connection_id
            AND releases.kind = 'release'
            AND releases.summary->>'tag' = repo_activity_events.summary->>'tag'
        ))
      SQL

    after_create_commit :count_daily_push

    def self.pushes_today(connection_id)
      key = push_count_key(connection_id, Time.current)
      if Discourse.redis.exists?(key)
        Discourse.redis.scard(key)
      else
        where(connection_id: connection_id, kind: "push").where(
          "created_at >= ?",
          Time.current.beginning_of_day,
        ).count
      end
    end

    def self.push_count_key(connection_id, time)
      "repo-activity:pushes:#{connection_id}:#{time.utc.to_date}"
    end

    private

    def count_daily_push
      return unless kind == "push"
      key = self.class.push_count_key(connection_id, created_at)
      # Event IDs make retry/backfill idempotent. This survives the 50-event prune.
      ids = [id]
      unless Discourse.redis.exists?(key)
        ids =
          self
            .class
            .where(connection_id: connection_id, kind: "push")
            .where(created_at: created_at.beginning_of_day...created_at.end_of_day)
            .pluck(:id)
      end
      ids.each_slice(1000) { |slice| Discourse.redis.sadd(key, slice) }
      Discourse.redis.expire(key, 2.days.to_i)
    end
  end
end
