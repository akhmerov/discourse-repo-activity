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
          keep = connection.events.order(id: :desc).limit(50).pluck(:id)
          connection.events.where.not(id: keep).delete_all
          connection
            .refs
            .where(
              "kind = ? OR (kind = ? AND ref_name != ?)",
              "pr",
              "branch",
              connection.default_branch.to_s
            )
            .where("updated_at < ?", 14.days.ago)
            .delete_all
        end
      rescue StandardError => error
        Rails.logger.warn(
          "Repository activity prune failed for connection #{connection.id}: #{error.class}"
        )
      end
      DiscourseRepoActivity::Connection
        .where.not(chat_channel_id: ::Chat::Channel.select(:id))
        .delete_all
    end
  end
end
