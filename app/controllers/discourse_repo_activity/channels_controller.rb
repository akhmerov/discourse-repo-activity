# frozen_string_literal: true

module DiscourseRepoActivity
  class ChannelsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    requires_login
    before_action :find_channel

    def show
      render json: Snapshot.for(@channel, current_user)
    end

    def read
      # Only acknowledge what this client actually displayed; a concurrent event stays new.
      id = params.require(:last_seen_event_id).to_i
      maximum = Event.where(chat_channel_id: @channel.id).maximum(:id).to_i
      raise Discourse::InvalidParameters unless id.between?(0, maximum)
      DB.exec(
        <<~SQL,
        INSERT INTO repo_activity_channel_reads (user_id, chat_channel_id, last_seen_event_id)
        VALUES (:user_id, :channel_id, :event_id)
        ON CONFLICT (user_id, chat_channel_id) DO UPDATE
        SET last_seen_event_id = GREATEST(repo_activity_channel_reads.last_seen_event_id, EXCLUDED.last_seen_event_id)
      SQL
        user_id: current_user.id,
        channel_id: @channel.id,
        event_id: id
      )
      render json: success_json
    end

    private

    def find_channel
      @channel = Chat::Channel.find_by(id: params[:channel_id])
      unless DiscourseRepoActivity.can_view?(@channel, current_user)
        raise Discourse::NotFound
      end
    end
  end
end
