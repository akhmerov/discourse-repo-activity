# frozen_string_literal: true

module DiscourseRepoActivity
  # Capability used only by the announcement services. No group grants, staff
  # privileges or global Guardian overrides are given to the dedicated bot.
  class BotGuardian < ::Guardian
    def initialize(connection)
      super(Bot.user)
      @connection = connection
    end

    def can_preview_chat_channel?(channel)
      channel&.id == @connection.chat_channel_id && @connection.active_channel?
    end

    def can_post_in_chatable?(chatable, **_options)
      chatable == @connection.chat_channel.chatable &&
        @connection.active_channel?
    end

    def can_see_chatable?(chatable)
      can_post_in_chatable?(chatable)
    end
  end
end
