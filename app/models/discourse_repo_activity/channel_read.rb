# frozen_string_literal: true

module DiscourseRepoActivity
  class ChannelRead < ActiveRecord::Base
    self.table_name = "repo_activity_channel_reads"
    self.primary_key = %i[user_id chat_channel_id]
  end
end
