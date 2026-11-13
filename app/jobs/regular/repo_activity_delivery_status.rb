# frozen_string_literal: true

module Jobs
  class RepoActivityDeliveryStatus < ::Jobs::Base
    def execute(args)
      id = args[:connection_id]
      Discourse.redis.del("repo-activity:status-flush:#{id}")
      return unless SiteSetting.repo_activity_enabled
      connection = DiscourseRepoActivity::Connection.find_by(id: id)
      DiscourseRepoActivity::DeliveryStatus.flush(connection) if connection&.active_channel?
    end
  end
end
