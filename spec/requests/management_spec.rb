# frozen_string_literal: true

RSpec.describe "Repository management" do
  fab!(:admin)
  fab!(:member, :user)
  fab!(:channel, :chat_channel)
  fab!(:connection) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: admin,
      forge: "github",
      host: "github.com",
      repo_path: "acme/sim-tools",
    )
  end

  before do
    SiteSetting.chat_enabled = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    SiteSetting.repo_activity_enabled = true
  end

  it "keeps management secrets separate from viewer snapshots" do
    sign_in(member)
    get "/repo-activity/channels/#{channel.id}.json"
    expect(response.status).to eq(200)
    expect(response.body).not_to include(connection.secret, connection.public_id)
    get "/repo-activity/channels/#{channel.id}/connections.json"
    expect(response.status).to eq(403)
    sign_in(admin)
    get "/repo-activity/channels/#{channel.id}/connections.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["connections"].first).not_to have_key("secret")
    get "/repo-activity/channels/#{channel.id}/connections/#{connection.id}/secret.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["secret"] == connection.secret).to eq(true)
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "rotates the derived secret without storing it" do
    old = connection.secret
    sign_in(admin)
    post "/repo-activity/channels/#{channel.id}/connections/#{connection.id}/rotate.json"
    expect(response.status).to eq(200)
    expect(connection.reload.secret_version).to eq(2)
    expect(connection.secret).not_to eq(old)
    expect(connection.attributes.keys).not_to include("secret")
  end

  it "marks only displayed events seen and never moves backwards" do
    older = connection.events.create!(chat_channel_id: channel.id, kind: "push")
    newer = connection.events.create!(chat_channel_id: channel.id, kind: "push")
    sign_in(member)
    put "/repo-activity/channels/#{channel.id}/read.json", params: { last_seen_event_id: older.id }
    get "/repo-activity/channels/#{channel.id}.json"
    expect(response.parsed_body["new_count"]).to eq(1)
    put "/repo-activity/channels/#{channel.id}/read.json", params: { last_seen_event_id: newer.id }
    put "/repo-activity/channels/#{channel.id}/read.json", params: { last_seen_event_id: older.id }
    get "/repo-activity/channels/#{channel.id}.json"
    expect(response.parsed_body["new_count"]).to eq(0)
  end

  it "rejects private channel snapshots from outsiders" do
    private_channel = Fabricate(:private_category_channel)
    sign_in(member)
    get "/repo-activity/channels/#{private_channel.id}.json"
    expect(response.status).to eq(404)
  end

  it "has no per-connection event setting in storage or the management API" do
    sign_in(admin)
    get "/repo-activity/channels/#{channel.id}/connections.json"
    expect(response.parsed_body["connections"].sole).not_to have_key("enabled_events")
    expect(connection.has_attribute?(:enabled_events)).to eq(false)
  end

  it "rejects DM connections both through the API and model" do
    DiscourseRepoActivity::Bot.ensure!
    dm = Fabricate(:direct_message_channel, users: [admin, member])
    sign_in(admin)
    post "/repo-activity/channels/#{dm.id}/connections.json",
         params: {
           forge: "github",
           host: "github.com",
           repo_path: "acme/private",
         }
    expect(response.status).to eq(403)
    invalid = connection.dup
    invalid.chat_channel = dm
    invalid.public_id = SecureRandom.hex(20)
    expect(invalid).not_to be_valid
    expect(invalid.errors[:chat_channel]).to be_present
    expect(
      dm.user_chat_channel_memberships.where(user_id: DiscourseRepoActivity::Bot.user.id),
    ).to be_empty
  end

  it "publishes monotone read acknowledgements only to the reading user" do
    event = connection.events.create!(chat_channel_id: channel.id, kind: "push")
    sign_in(member)
    messages =
      MessageBus.track_publish("/repo-activity/#{channel.id}") do
        [event.id, 0].each do |id|
          put "/repo-activity/channels/#{channel.id}/read.json", params: { last_seen_event_id: id }
          expect(response.status).to eq(200)
        end
      end
    expect(messages.size).to eq(2)
    messages.each do |message|
      expect(message.data).to eq(last_seen_event_id: event.id, new_count: 0)
      expect(message.user_ids).to eq([member.id])
      expect(
        MessageBus::Client.new(
          client_id: "other",
          user_id: admin.id,
          message_bus: MessageBus,
        ).allowed?(message),
      ).to eq(false)
    end
  end

  it "schedules update and rotation publication after leaving the row lock" do
    sign_in(admin)
    baseline = DiscourseRepoActivity::Connection.connection.open_transactions
    DiscourseRepoActivity::Snapshot
      .expects(:publish)
      .with do |published_channel|
        expect(DiscourseRepoActivity::Connection.connection.open_transactions).to eq(baseline)
        published_channel.id == channel.id
      end
      .twice
    put "/repo-activity/channels/#{channel.id}/connections/#{connection.id}.json",
        params: {
          enabled: false,
        }
    expect(response.status).to eq(200)
    post "/repo-activity/channels/#{channel.id}/connections/#{connection.id}/rotate.json"
    expect(response.status).to eq(200)
  end

  it "authorizes status and explicit secret access and never shares status with viewers" do
    DiscourseRepoActivity::DeliveryStatus.reject_unverified(connection, "wrong_secret")
    sign_in(member)
    get "/repo-activity/channels/#{channel.id}/connections/#{connection.id}/secret.json"
    expect(response.status).to eq(403)
    get "/repo-activity/channels/#{channel.id}.json"
    expect(response.body).not_to include("delivery_status", "rejected_deliveries", "wrong_secret")
    sign_in(admin)
    get "/repo-activity/channels/#{channel.id}/connections.json"
    row = response.parsed_body.fetch("connections").sole
    expect(row).to include("delivery_status" => "wrong_secret", "rejected_deliveries" => 1)
    expect(row).not_to have_key("secret")
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "sends management invalidations only to registered current managers" do
    sign_in(admin)
    get "/repo-activity/channels/#{channel.id}/connections.json"
    DiscourseRepoActivity::DeliveryStatus.watch(channel, member)
    messages =
      MessageBus.track_publish("/repo-activity/management/#{channel.id}") do
        DiscourseRepoActivity::DeliveryStatus.reject_unverified(connection, "wrong_secret")
      end
    expect(messages.sole.user_ids).to eq([admin.id])
    expect(messages.sole.data).to eq(refresh: true)
    freeze_time 61.seconds.from_now
    admin.update!(suspended_till: 1.year.from_now)
    expect(DiscourseRepoActivity.can_manage?(channel, User.find(admin.id))).to eq(false)
    messages =
      MessageBus.track_publish("/repo-activity/management/#{channel.id}") do
        DiscourseRepoActivity::DeliveryStatus.reject_unverified(connection, "missing_signature")
      end
    expect(messages).to be_empty
  end

  it "rotates one connection and requires a new verified setup delivery" do
    sign_in(admin)
    previous = connection.secret
    DiscourseRepoActivity::DeliveryStatus.record(connection, "receiving")
    post "/repo-activity/channels/#{channel.id}/connections/#{connection.id}/rotate.json"
    expect(response.status).to eq(200)
    expect(connection.reload.secret == previous).to eq(false)
    expect(connection.delivery_status).to eq("waiting")
    expect(response.parsed_body).not_to have_key("secret")
  end

  it "keeps repository rows in a stable order after state updates" do
    other =
      DiscourseRepoActivity::Connection.create!(
        chat_channel: channel,
        created_by: admin,
        forge: "github",
        host: "github.com",
        repo_path: "acme/another",
      )
    connection.update!(enabled: false)
    sign_in(admin)
    get "/repo-activity/channels/#{channel.id}/connections.json"
    expect(response.parsed_body.fetch("connections").map { |row| row.fetch("id") }).to eq(
      [connection.id, other.id],
    )
  end
end
