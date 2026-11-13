# frozen_string_literal: true

module Jobs
  class RepoActivityPrune < ::Jobs::Scheduled
    every 1.day

    def execute(_args)
      DiscourseRepoActivity::Connection.find_each do |connection|
        if SiteSetting.repo_activity_enabled && connection.active_channel? &&
             connection.events.where(loud: true, chat_message_id: nil).exists?
          DiscourseRepoActivity::Announcer.new(connection).announce
        end
        connection.with_lock do
          connection.events.where("created_at < ?", 14.days.ago).delete_all
          # Keep whole pushes, never a partial commit list. Also bound non-push events.
          commits = 0
          keep =
            connection
              .events
              .order(id: :desc)
              .limit(1000)
              .filter_map do |event|
                commits += [Array(event.summary["commits"]).size, 1].max if event.kind == "push"
                event.id if event.kind != "push" || commits <= 500
              end
          connection.events.where.not(id: keep).delete_all
          connection
            .refs
            .where(
              "kind = ? OR (kind = ? AND ref_name != ?)",
              "pr",
              "branch",
              connection.default_branch.to_s,
            )
            .where("updated_at < ?", 14.days.ago)
            .delete_all
        end
      rescue StandardError => error
        Rails.logger.warn(
          "Repository activity prune failed for connection #{connection.id}: #{error.class}",
        )
      end
      DiscourseRepoActivity::Connection
        .where.not(chat_channel_id: ::Chat::Channel.select(:id))
        .delete_all
    end
  end
end
