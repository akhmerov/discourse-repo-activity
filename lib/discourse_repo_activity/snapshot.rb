# frozen_string_literal: true

module DiscourseRepoActivity
  module Snapshot
    def self.for(channel, user = nil)
      message_bus_last_id = MessageBus.last_id("/repo-activity/#{channel.id}")
      seen =
        user &&
          ChannelRead.find_by(user_id: user.id, chat_channel_id: channel.id)&.last_seen_event_id
      stream_data = stream(channel)

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
                  "updated_at",
                )
              end
            latest = c.events.order(id: :desc).first
            default_ref =
              refs.find { |r| r["kind"] == "branch" && r["ref_name"] == c.default_branch }
            {
              id: c.id,
              display_name: c.display_name,
              url: c.repository_url,
              enabled: c.enabled,
              default_branch: c.default_branch,
              default_ref: default_ref,
              failing: c.enabled? && default_ref&.dig("ci_state") == "failed",
              state: c.enabled? ? default_ref&.dig("ci_state") || "none" : "paused",
              last_activity_at: latest&.created_at,
              new_count: user ? c.events.visible.where("id > ?", seen.to_i).count : nil,
            }
          end
      {
        repos: repos.sort_by { |r| [r[:failing] ? 0 : 1, -(r[:last_activity_at]&.to_f || 0)] },
        **stream_data,
        message_bus_last_id: message_bus_last_id,
        last_seen_event_id: seen.to_i,
        latest_event_id: stream_data[:stream].first&.dig("id") || 0,
        new_count:
          (
            if user
              Event.visible.where(chat_channel_id: channel.id).where("id > ?", seen.to_i).count
            else
              nil
            end
          ),
        can_manage: user && DiscourseRepoActivity.can_manage?(channel, user),
      }
    end

    # A bounded arrival-ordered page; CI updates decorate pushes, never flood the stream.
    def self.stream(channel, before: nil, connection_id: nil)
      scope = Event.visible.where(chat_channel_id: channel.id)
      scope = scope.where(connection_id: connection_id) if connection_id.present?
      scope = scope.where("id < ?", before.to_i) if before.present?
      page = scope.order(id: :desc).limit(31).to_a
      more = page.length > 30
      page = page.first(30)
      refs =
        Ref
          .where(connection_id: page.map(&:connection_id))
          .index_by { |r| [r.connection_id, r.ref_name] }
      {
        stream:
          page.map do |event|
            data =
              event.attributes.slice(
                "id",
                "connection_id",
                "kind",
                "actor_login",
                "summary",
                "created_at",
              )
            ref = refs[[event.connection_id, event.summary["ref"]]]
            if ref && ref.head_sha == event.summary["sha"]
              data["ci_state"] = ref.ci_state
              data["ci_runs"] = ref.ci_runs.first(10).to_h
            end
            data
          end,
        earlier_before: more ? page.last.id : nil,
      }
    end

    def self.publish(channel)
      return if channel.nil? || channel.trashed?
      if Discourse.redis.set(
           "repo-activity:publish:#{channel.id}",
           "1",
           nx: true,
           ex: 1.minute.to_i,
         )
        Jobs.enqueue_in(1.second, :repo_activity_publish, channel_id: channel.id)
      end
    end

    def self.publish_now(channel)
      return if channel.nil? || channel.trashed?
      payload = {
        latest_event_id: Event.visible.where(chat_channel_id: channel.id).maximum(:id).to_i,
        refresh: true,
      }
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
