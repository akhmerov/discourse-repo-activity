# frozen_string_literal: true

module DiscourseRepoActivity
  module Snapshot
    def self.for(channel, user = nil)
      message_bus_last_id = MessageBus.last_id("/repo-activity/#{channel.id}")
      seen =
        user &&
          ChannelRead.find_by(
            user_id: user.id,
            chat_channel_id: channel.id
          )&.last_seen_event_id
      # Fetch each repository's own recent window: a noisy repository must not
      # hide a quieter repository's history from the channel snapshot.
      events = Event.find_by_sql([<<~SQL, channel.id])
        SELECT * FROM (
          SELECT repo_activity_events.*,
                 row_number() OVER (PARTITION BY connection_id ORDER BY id DESC) AS event_rank
          FROM repo_activity_events WHERE chat_channel_id = ?
        ) recent WHERE event_rank <= 50 ORDER BY id DESC
      SQL

      repos =
        Connection
          .where(chat_channel_id: channel.id)
          .includes(:refs)
          .map do |c|
            refs =
              c.refs.map do |r|
                r.attributes.slice(
                  "ref_name",
                  "kind",
                  "pr_number",
                  "head_sha",
                  "pushed_by_login",
                  "ci_state",
                  "ci_runs",
                  "updated_at"
                )
              end
            recent = events.select { |e| e.connection_id == c.id }.first(50)
            default_ref =
              refs.find do |r|
                r["kind"] == "branch" && r["ref_name"] == c.default_branch
              end
            {
              id: c.id,
              display_name: c.display_name,
              url: c.repository_url,
              enabled: c.enabled,
              default_branch: c.default_branch,
              default_ref: default_ref,
              refs: refs,
              failing: default_ref&.dig("ci_state") == "failed",
              last_activity_at: recent.first&.created_at,
              pushes_today: Event.pushes_today(c.id),
              events:
                recent.map do |e|
                  e.attributes.slice(
                    "id",
                    "kind",
                    "actor_login",
                    "summary",
                    "created_at"
                  )
                end
            }
          end
      {
        repos:
          repos.sort_by do |r|
            [r[:failing] ? 0 : 1, -(r[:last_activity_at]&.to_f || 0)]
          end,
        message_bus_last_id: message_bus_last_id,
        last_seen_event_id: seen.to_i,
        latest_event_id: events.first&.id || 0,
        new_count:
          (
            if user
              Event
                .where(chat_channel_id: channel.id)
                .where("id > ?", seen.to_i)
                .count
            else
              nil
            end
          ),
        can_manage: user && DiscourseRepoActivity.can_manage?(channel, user)
      }
    end

    def self.publish(channel)
      return if channel.nil? || channel.trashed?
      if Discourse.redis.set(
           "repo-activity:publish:#{channel.id}",
           "1",
           nx: true,
           ex: 1.minute.to_i
         )
        Jobs.enqueue_in(
          1.second,
          :repo_activity_publish,
          channel_id: channel.id
        )
      end
    end

    def self.publish_now(channel)
      return if channel.nil? || channel.trashed?
      payload =
        self.for(channel).except(:last_seen_event_id, :new_count, :can_manage)
      payload[:event_ids] = Event.where(chat_channel_id: channel.id).pluck(:id)
      permissions = Chat::Publisher.permissions(channel)
      if permissions.empty?
        # Native public-channel publication is global; never broadcast repo
        # activity to anonymous clients. An empty group list would mean "no
        # restriction" to MessageBus, so publish nothing in that case.
        group_ids =
          if Chat.respond_to?(:message_bus_allowed_group_ids)
            Chat.message_bus_allowed_group_ids
          else
            []
          end
        return if group_ids.blank?
        permissions = { group_ids: group_ids }
      end
      MessageBus.publish("/repo-activity/#{channel.id}", payload, **permissions)
    end
  end
end
