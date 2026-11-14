# frozen_string_literal: true

module DiscourseRepoActivity
  class Connection < ActiveRecord::Base
    self.table_name = "repo_activity_connections"
    self.ignored_columns = %w[enabled_events]
    belongs_to :chat_channel, class_name: "Chat::Channel"
    belongs_to :created_by, class_name: "User"
    has_many :refs, class_name: "DiscourseRepoActivity::Ref", dependent: :delete_all
    has_many :events, class_name: "DiscourseRepoActivity::Event", dependent: :delete_all
    before_validation :normalize, on: :create
    after_update :discard_pending_if_disabled
    validate do
      errors.add(:chat_channel, "must be a category channel") unless chat_channel&.category_channel?
    end
    validates :forge, inclusion: { in: %w[github gitlab] }
    validates :host,
              format: {
                with: /\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]{1,5})?\z/,
              },
              length: {
                maximum: 253,
              }
    validates :repo_path, format: { with: %r{\A[\w.-]+(?:/[\w.-]+)+\z} }, length: { maximum: 500 }
    validates :repo_path, uniqueness: { scope: %i[chat_channel_id host] }
    validates :display_name, presence: true, length: { maximum: 100 }
    validates :public_id, presence: true, uniqueness: true
    validate do
      if repo_path.to_s.split("/").any? { |s| %w[. ..].include?(s) }
        errors.add(:repo_path, "contains invalid segments")
      end
    end

    def active_channel?
      SiteSetting.chat_enabled && enabled? && chat_channel && chat_channel.category_channel? &&
        !chat_channel.trashed? && chat_channel.open? && chat_channel.chatable.present?
    end

    def secret
      OpenSSL::HMAC.hexdigest(
        "SHA256",
        Rails.application.secret_key_base,
        "repo-activity:#{id}:#{secret_version}",
      )
    end

    def repository_url
      "https://#{host}/#{repo_path}"
    end

    # Resolve collisions within a channel only, without loading each repo separately.
    def self.display_labels(connections)
      connections
        .group_by { |c| [c.chat_channel_id, c.display_name] }
        .values
        .flat_map do |group|
          group.map do |connection|
            name = connection.display_name
            if group.length > 1
              name = connection.repo_path
              name = "#{connection.host}/#{name}" if group.count { |c| c.repo_path == name } > 1
            end
            [connection.id, name]
          end
        end
        .to_h
    end

    def management_json
      attributes.slice(
        "id",
        "forge",
        "host",
        "repo_path",
        "display_name",
        "enabled",
        "last_delivery_at",
        "last_delivery_error",
        "last_delivery_error_at",
        "delivery_status",
        "missing_hook_events",
      ).merge(
        webhook_url: "#{Discourse.base_url}/repo-activity/hooks/#{public_id}",
        repository_url: repository_url,
        rejected_deliveries: DeliveryStatus.count(self),
        recent_event_types:
          received_event_types.select { |_kind, time| Time.iso8601(time) >= 7.days.ago }.keys,
        **DeliveryStatus.management_state(self),
      )
    end

    def discard_pending!
      events.where(loud: true, chat_message_id: nil).update_all(loud: false)
    end

    private

    def discard_pending_if_disabled
      if saved_change_to_enabled?
        discard_pending! unless enabled?
        DeliveryStatus.clear(self)
        update_columns(
          delivery_status: last_delivery_at ? "receiving" : "waiting",
          last_delivery_error: nil,
          last_delivery_error_at: nil,
          rejected_deliveries: 0,
        )
      end
    end

    def normalize
      self.host = host.to_s.strip.downcase
      self.repo_path =
        repo_path.to_s.strip.sub(%r{\A/+}, "").sub(%r{/+\z}, "").delete_suffix(".git")
      self.repo_path = repo_path.downcase if forge == "github"
      self.display_name = (display_name.presence || repo_path.split("/").last).gsub(/\p{Cf}/, "")
      self.public_id ||= SecureRandom.hex(20)
    end
  end
end
