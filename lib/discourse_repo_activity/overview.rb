# frozen_string_literal: true

module DiscourseRepoActivity
  module Overview
    def self.for(ids, user)
      guardian = user.guardian
      return {} if user.suspended? || !guardian.can_chat?
      channels =
        Chat::Channel
          .where(id: ids, chatable_type: "Category", deleted_at: nil)
          .includes(:chatable)
          .select { |channel| guardian.can_preview_chat_channel?(channel) }
      ids = channels.map(&:id)
      return {} if ids.empty?
      bus_ids =
        channels.to_h { |channel| [channel.id, MessageBus.last_id("/repo-activity/#{channel.id}")] }
      connections = Connection.where(chat_channel_id: ids).includes(:refs).order(:id).to_a
      latest =
        Event.where(connection_id: connections.map(&:id)).group(:connection_id).maximum(:created_at)
      # Exactly the header/stream predicate and shared per-user cursor; no event
      # payloads, secrets, or manager-only delivery diagnostics leave this endpoint.
      join =
        Event.sanitize_sql_array(
          [
            "LEFT JOIN repo_activity_channel_reads reads ON reads.chat_channel_id = repo_activity_events.chat_channel_id AND reads.user_id = ?",
            user.id,
          ],
        )
      counts =
        Event
          .visible
          .where(chat_channel_id: ids)
          .joins(join)
          .where("repo_activity_events.id > COALESCE(reads.last_seen_event_id, 0)")
          .group(:chat_channel_id)
          .count
      grouped = connections.group_by(&:chat_channel_id)
      channels.to_h do |channel|
        repos =
          Array(grouped[channel.id]).map do |connection|
            ref =
              connection.refs.find do |item|
                item.kind == "branch" && item.ref_name == connection.default_branch
              end
            {
              id: connection.id,
              name: connection.display_name,
              branch: connection.default_branch,
              state: connection.enabled? ? ref&.ci_state || "none" : "paused",
              updated_at: ref&.updated_at || latest[connection.id],
            }
          end
        repos.sort_by! { |repo| [repo[:state] == "failed" ? 0 : 1, repo[:id]] }
        [
          channel.id,
          {
            repos: repos,
            new_count: counts.fetch(channel.id, 0),
            message_bus_last_id: bus_ids[channel.id],
          },
        ]
      end
    end
  end
end
