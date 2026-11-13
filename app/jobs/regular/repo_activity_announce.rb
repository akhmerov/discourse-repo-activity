# frozen_string_literal: true

module Jobs
  class RepoActivityAnnounce < ::Jobs::Base
    def execute(args)
      Discourse.redis.del("repo-activity:announce:#{args[:connection_id]}")
      return unless SiteSetting.repo_activity_enabled
      connection = DiscourseRepoActivity::Connection.find_by(id: args[:connection_id])
      DiscourseRepoActivity::Announcer.new(connection).announce if connection
    end
  end
end
