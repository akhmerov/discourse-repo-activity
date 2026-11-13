# frozen_string_literal: true

# name: discourse-repo-activity
# about: Receive GitHub and GitLab activity in chat channels.
# version: 0.1
# authors: Anton Akhmerov
# license: MIT

enabled_site_setting :repo_activity_enabled
register_asset "stylesheets/common/repo-activity.scss"

module ::DiscourseRepoActivity
  PLUGIN_NAME = "discourse-repo-activity"

  def self.can_view?(channel, user)
    user.present? && !user.suspended? && channel.present? && !channel.trashed? &&
      user.guardian.can_chat? && user.guardian.can_preview_chat_channel?(channel)
  end

  # One extension point, shared by the API and both management entry points.
  def self.can_manage?(channel, user)
    channel&.category_channel? && can_view?(channel, user) &&
      DiscoursePluginRegistry.apply_modifier(
        :repo_activity_channel_manager,
        user.staff?,
        channel,
        user,
      )
  end
end

require_relative "lib/discourse_repo_activity/engine"
require_relative "lib/discourse_repo_activity/signature"
require_relative "lib/discourse_repo_activity/parser"
require_relative "lib/discourse_repo_activity/processor"
require_relative "lib/discourse_repo_activity/bot"
require_relative "lib/discourse_repo_activity/announcer"
require_relative "lib/discourse_repo_activity/snapshot"

after_initialize do
  require_relative "lib/discourse_repo_activity/bot_guardian"

  require_relative "lib/discourse_repo_activity/incident_replies"
  Chat::CreateMessage.singleton_class.prepend(DiscourseRepoActivity::IncidentReplies)
  on(:chat_message_created) { |message| DiscourseRepoActivity::Announcer.preserve_reply(message) }

  Discourse::Application.routes.append do
    mount ::DiscourseRepoActivity::Engine, at: "/repo-activity"
  end
end
