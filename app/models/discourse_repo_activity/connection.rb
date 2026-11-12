# frozen_string_literal: true

module DiscourseRepoActivity
  class Connection < ActiveRecord::Base
    self.table_name = "repo_activity_connections"
    EVENTS = %w[
      push
      ci
      failure
      recovery
      release
      tag
      pr_opened
      pr_merged
      issue_opened
    ].freeze
    belongs_to :chat_channel, class_name: "Chat::Channel"
    belongs_to :created_by, class_name: "User"
    has_many :refs,
             class_name: "DiscourseRepoActivity::Ref",
             dependent: :delete_all
    has_many :events,
             class_name: "DiscourseRepoActivity::Event",
             dependent: :delete_all
    before_validation :normalize, on: :create
    after_update :discard_pending_if_disabled
    validate do
      unless chat_channel&.category_channel?
        errors.add(:chat_channel, "must be a category channel")
      end
    end
    validates :forge, inclusion: { in: %w[github gitlab] }
    validates :host,
              format: {
                with: /\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]{1,5})?\z/
              },
              length: {
                maximum: 253
              }
    validates :repo_path,
              format: {
                with: %r{\A[\w.-]+(?:/[\w.-]+)+\z}
              },
              length: {
                maximum: 500
              }
    validates :repo_path, uniqueness: { scope: %i[chat_channel_id host] }
    validates :display_name, presence: true, length: { maximum: 100 }
    validates :public_id, presence: true, uniqueness: true
    validate do
      unless enabled_events.is_a?(Array) && (enabled_events - EVENTS).empty?
        errors.add(:enabled_events, "contains unknown events")
      end
      if repo_path.to_s.split("/").any? { |s| %w[. ..].include?(s) }
        errors.add(:repo_path, "contains invalid segments")
      end
    end

    def active_channel?
      SiteSetting.chat_enabled && enabled? && chat_channel &&
        chat_channel.category_channel? && !chat_channel.trashed? &&
        chat_channel.open? && chat_channel.chatable.present?
    end

    def secret
      OpenSSL::HMAC.hexdigest(
        "SHA256",
        Rails.application.secret_key_base,
        "repo-activity:#{id}:#{secret_version}"
      )
    end

    def repository_url
      "https://#{host}/#{repo_path}"
    end

    def management_json
      attributes.slice(
        "id",
        "forge",
        "host",
        "repo_path",
        "display_name",
        "enabled_events",
        "enabled",
        "last_delivery_at",
        "last_delivery_error"
      ).merge(
        webhook_url: "#{Discourse.base_url}/repo-activity/hooks/#{public_id}",
        secret: secret
      )
    end

    def discard_pending!
      events.where(loud: true, chat_message_id: nil).update_all(loud: false)
      refs.update_all(failing_since: nil, failure_message_id: nil)
    end

    private

    def discard_pending_if_disabled
      discard_pending! if saved_change_to_enabled? && !enabled?
    end

    def normalize
      self.host = host.to_s.strip.downcase
      self.repo_path =
        repo_path
          .to_s
          .strip
          .sub(%r{\A/+}, "")
          .sub(%r{/+\z}, "")
          .delete_suffix(".git")
      self.repo_path = repo_path.downcase if forge == "github"
      self.display_name = display_name.presence || repo_path.split("/").last
      self.public_id ||= SecureRandom.hex(20)
    end
  end
end
