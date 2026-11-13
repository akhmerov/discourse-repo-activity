# frozen_string_literal: true

module DiscourseRepoActivity
  class ConnectionsController < ChannelsController
    before_action :ensure_manager

    def index
      response.headers["Cache-Control"] = "no-store"
      DeliveryStatus.watch(@channel, current_user)
      last_id = MessageBus.last_id("/repo-activity/management/#{@channel.id}")
      render json: {
               message_bus_last_id: last_id,
               connections:
                 Connection.where(chat_channel_id: @channel.id).order(:id).map(&:management_json),
             }
    end

    def create
      connection =
        Connection.new(connection_params.merge(chat_channel: @channel, created_by: current_user))
      save_and_render(connection)
      Snapshot.publish(@channel) if connection.errors.empty?
    end

    def update
      connection = find_connection
      connection.with_lock do
        connection.assign_attributes(params.permit(:enabled))
        save_and_render(connection)
      end
      Snapshot.publish(@channel) if connection.errors.empty?
    end

    def rotate
      connection = find_connection
      connection.with_lock do
        connection.secret_version += 1
        connection.delivery_status = "waiting"
        connection.missing_hook_events = []
        connection.rejected_deliveries = 0
        Discourse.redis.del("repo-activity:rejected:#{connection.id}")
        save_and_render(connection)
      end
      Snapshot.publish(@channel) if connection.errors.empty?
    end

    def secret
      response.headers["Cache-Control"] = "no-store"
      render json: { secret: find_connection.secret }
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
      params.permit(:forge, :host, :repo_path, :display_name, :enabled)
    end

    def save_and_render(connection)
      if connection.save
        response.headers["Cache-Control"] = "no-store"
        render json: connection.management_json
      else
        render json: { errors: connection.errors.full_messages }, status: :unprocessable_entity
      end
    end
  end
end
