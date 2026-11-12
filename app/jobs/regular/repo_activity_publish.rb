# frozen_string_literal: true

module Jobs
  class RepoActivityPublish < ::Jobs::Base
    def execute(args)
      Discourse.redis.del("repo-activity:publish:#{args[:channel_id]}")
      return unless SiteSetting.repo_activity_enabled
      DiscourseRepoActivity::Snapshot.publish_now(
        ::Chat::Channel.find_by(id: args[:channel_id])
      )
    end
  end
end
