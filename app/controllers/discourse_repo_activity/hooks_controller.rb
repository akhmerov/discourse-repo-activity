# frozen_string_literal: true

module DiscourseRepoActivity
  class HooksController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    skip_before_action :verify_authenticity_token,
                       :redirect_to_login_if_required,
                       :redirect_to_profile_if_required,
                       :check_xhr
    MAX_BODY = 1.megabyte

    # Instrumentation emits start_processing before callbacks and append_info_to_payload.
    # Suppress the complete hook parameter map before entering that instrumentation.
    def process_action(*)
      # Rails' JSON parser also logs raw malformed bodies. Hooks decode only
      # after signature verification, so bypass automatic body parsing entirely.
      request.request_parameters = {}
      request.define_singleton_method(:filtered_parameters) { {} }
      super
    end

    def create
      connection = Connection.find_by(public_id: request.path_parameters[:public_id])
      raise Discourse::NotFound unless connection
      body = request.body.read(MAX_BODY + 1)
      if body.bytesize > MAX_BODY
        DeliveryStatus.reject_unverified(connection, "invalid_payload")
        return head :payload_too_large
      end
      unless Signature.valid?(connection, body, request.headers)
        RateLimiter.new(
          nil,
          "repo-activity:invalid:#{connection.id}:#{request.remote_ip}",
          120,
          1.minute,
        ).performed!
        header = connection.forge == "github" ? "X-Hub-Signature-256" : "X-Gitlab-Token"
        DeliveryStatus.reject_unverified(
          connection,
          request.headers[header].blank? ? "missing_signature" : "wrong_secret",
        )
        return head :unauthorized
      end
      RateLimiter.new(nil, "repo-activity:#{connection.id}", 120, 1.minute).performed!
      return head :not_found unless connection.active_channel?
      delivery =
        request.headers[
          connection.forge == "github" ? "X-GitHub-Delivery" : "X-Gitlab-Event-UUID"
        ].to_s
      if delivery.blank? || delivery.bytesize > 200
        DeliveryStatus.record(connection, "invalid_payload")
        return head :bad_request
      end
      key = "repo-activity:delivery:#{connection.id}:#{Digest::SHA256.hexdigest(delivery)}"
      return head :ok unless Discourse.redis.set(key, "1", nx: true, ex: 24.hours.to_i)
      begin
        connection.with_lock do
          connection.chat_channel.with_lock do
            unless connection.active_channel?
              Discourse.redis.del(key)
              return head :not_found
            end
            unless Signature.valid?(connection, body, request.headers)
              Discourse.redis.del(key)
              DeliveryStatus.reject_unverified(connection, "wrong_secret")
              return head :unauthorized
            end
            # GitHub signs the form envelope, not the decoded JSON value.
            json =
              if connection.forge == "github" &&
                   request.media_type == "application/x-www-form-urlencoded"
                values = URI.decode_www_form(body).select { |name, _| name == "payload" }
                raise Discourse::InvalidParameters unless values.length == 1
                values.first.last
              else
                body
              end
            payload = JSON.parse(json)
            raise Discourse::InvalidParameters unless payload.is_a?(Hash)
            event =
              request.headers[connection.forge == "github" ? "X-GitHub-Event" : "X-Gitlab-Event"]
            missing = nil
            if connection.forge == "github" && event == "ping"
              hook = payload["hook"]
              raise Discourse::InvalidParameters unless hook.nil? || hook.is_a?(Hash)
              enabled = hook&.fetch("events", nil)
              unless enabled.nil?
                raise Discourse::InvalidParameters unless enabled.is_a?(Array)
                raise Discourse::InvalidParameters unless enabled.all?(String)
              end
              enabled ||= []
              missing = enabled.include?("*") ? [] : DeliveryStatus::EVENTS - enabled
              status = "receiving"
            else
              parsed = Parser.new(connection, payload).parse(event)
              Processor.new(connection).process(parsed) if parsed
              status = "receiving"
            end
            connection.save! if connection.changed?
            type =
              {
                "push" => "push",
                "Push Hook" => "push",
                "workflow_run" => "pipeline",
                "Pipeline Hook" => "pipeline",
                "pull_request" => "pull_request",
                "Merge Request Hook" => "pull_request",
                "issues" => "issue",
                "Issue Hook" => "issue",
                "release" => "release",
                "Release Hook" => "release",
                "Tag Push Hook" => "tag",
              }[
                event
              ]
            type = "tag" if event == "push" && payload["ref"].to_s.start_with?("refs/tags/")
            DeliveryStatus.record(connection, status, missing: missing, event_type: type)
          end
        end
      rescue JSON::ParserError, ArgumentError, Discourse::InvalidParameters
        Discourse.redis.del(key)
        DeliveryStatus.record(connection, "invalid_payload")
        return head :bad_request
      rescue StandardError
        Discourse.redis.del(key)
        raise
      end
      Snapshot.publish(connection.chat_channel)
      head :ok
    end

    def append_info_to_payload(payload)
      super
      payload[:params] = {}
    end
  end
end
