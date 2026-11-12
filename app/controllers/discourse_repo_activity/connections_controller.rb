# frozen_string_literal: true

module DiscourseRepoActivity
  class ConnectionsController < ChannelsController
    before_action :ensure_manager

    def index
      response.headers["Cache-Control"] = "no-store"
      render json: {
               connections:
                 Connection.where(chat_channel_id: @channel.id).map(
                   &:management_json
                 )
             }
    end

    def create
      connection =
        Connection.new(
          connection_params.merge(
            chat_channel: @channel,
            created_by: current_user
          )
        )
      connection.enabled_events = Connection::EVENTS if !params.key?(
        :enabled_events
      )
      save_and_render(connection)
    end

    def update
      connection = find_connection
      connection.with_lock do
        connection.assign_attributes(
          params.permit(:enabled, enabled_events: [])
        )
        save_and_render(connection)
      end
    end

    def rotate
      connection = find_connection
      connection.with_lock do
        connection.secret_version += 1
        save_and_render(connection)
      end
    end

    def destroy
      connection = find_connection
      connection.with_lock { connection.destroy! }
      Snapshot.publish(@channel)
      render json: success_json
    end

    private

    def ensure_manager
      unless DiscourseRepoActivity.can_manage?(@channel, current_user)
        raise Discourse::InvalidAccess
      end
    end

    def find_connection
      Connection.find_by!(id: params[:id], chat_channel_id: @channel.id)
    end

    def connection_params
      params.permit(
        :forge,
        :host,
        :repo_path,
        :display_name,
        :enabled,
        enabled_events: []
      )
    end

    def save_and_render(connection)
      if connection.save
        Snapshot.publish(@channel)
        response.headers["Cache-Control"] = "no-store"
        render json: connection.management_json
      else
        render json: {
                 errors: connection.errors.full_messages
               },
               status: :unprocessable_entity
      end
    end
  end
end
