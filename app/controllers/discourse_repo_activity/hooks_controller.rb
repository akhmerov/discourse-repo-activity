# frozen_string_literal: true

module DiscourseRepoActivity
  class HooksController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    skip_before_action :verify_authenticity_token,
                       :redirect_to_login_if_required,
                       :redirect_to_profile_if_required,
                       :check_xhr
    MAX_BODY = 1.megabyte

    def create
      connection = Connection.find_by(public_id: params[:public_id])
      raise Discourse::NotFound unless connection&.active_channel?
      body = request.body.read(MAX_BODY + 1)
      return head :payload_too_large if body.bytesize > MAX_BODY
      unless Signature.valid?(connection, body, request.headers)
        RateLimiter.new(
          nil,
          "repo-activity:invalid:#{connection.id}:#{request.remote_ip}",
          120,
          1.minute,
        ).performed!
        record_error(connection, "Invalid signature")
        return head :unauthorized
      end
      RateLimiter.new(nil, "repo-activity:#{connection.id}", 120, 1.minute).performed!
      delivery =
        request.headers[
          (
            if connection.forge == "github"
              "X-GitHub-Delivery"
            else
              "X-Gitlab-Event-UUID"
            end
          )
        ].to_s
      raise Discourse::InvalidParameters if delivery.blank? || delivery.bytesize > 200
      key = "repo-activity:delivery:#{connection.id}:#{Digest::SHA256.hexdigest(delivery)}"
      return head :ok unless Discourse.redis.set(key, "1", nx: true, ex: 24.hours.to_i)
      begin
        connection.with_lock do
          connection.chat_channel.with_lock do
            # Recheck after locks: archive, disable and secret rotation can race delivery.
            raise Discourse::NotFound unless connection.active_channel?
            unless Signature.valid?(connection, body, request.headers)
              raise Discourse::InvalidAccess
            end
            payload = JSON.parse(body)
            raise Discourse::InvalidParameters unless payload.is_a?(Hash)
            event_name =
              request.headers[
                (
                  if connection.forge == "github"
                    "X-GitHub-Event"
                  else
                    "X-Gitlab-Event"
                  end
                )
              ]
            parsed = Parser.new(connection, payload).parse(event_name)
            Processor.new(connection).process(parsed) if parsed
            connection.update!(last_delivery_at: Time.current, last_delivery_error: nil)
          end
        end
      rescue JSON::ParserError, Discourse::InvalidParameters
        Discourse.redis.del(key)
        record_error(connection, "Invalid payload")
        return head :bad_request
      rescue StandardError
        Discourse.redis.del(key)
        raise
      end
      Discourse.redis.del("repo-activity:error:#{connection.id}")
      Snapshot.publish(connection.chat_channel)
      head :ok
    end

    # Raw webhook fields must not enter the Rails request log.
    def append_info_to_payload(payload)
      super
      payload[:params] = {}
    end

    private

    def record_error(connection, error)
      if Discourse.redis.set(
           "repo-activity:error:#{connection.id}",
           "1",
           nx: true,
           ex: 1.minute.to_i,
         )
        connection.update_columns(last_delivery_error: error)
      end
    end
  end
end
