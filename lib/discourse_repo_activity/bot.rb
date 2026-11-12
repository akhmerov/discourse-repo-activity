# frozen_string_literal: true

module DiscourseRepoActivity
  module Bot
    def self.user
      User.find(PluginStore.get(PLUGIN_NAME, "bot_user_id"))
    end

    def self.ensure!
      DistributedMutex.synchronize("repo-activity-bot") do
        id = PluginStore.get(PLUGIN_NAME, "bot_user_id")
        return User.find(id) if id && User.exists?(id: id)
        # Negative IDs are Discourse's bot contract. Allocate below existing bots.
        id = [User.minimum(:id).to_i - 1, -1000].min
        username = UserNameSuggester.suggest("repo-activity")
        bot =
          User.create!(
            id: id,
            username: username,
            name: "Repository activity",
            email: "repo-activity-#{id.abs}@invalid.invalid",
            password: SecureRandom.hex(32),
            active: true,
            approved: true,
            trust_level: 4
          )
        bot.user_option.update!(
          email_level: 2,
          email_messages_level: 2,
          email_digests: false
        )
        PluginStore.set(PLUGIN_NAME, "bot_user_id", bot.id)
        bot
      end
    end
  end
end
