# frozen_string_literal: true

RSpec.describe DiscourseRepoActivity::Snapshot do
  fab!(:admin)
  fab!(:member, :user)
  fab!(:outsider, :user)
  fab!(:group)
  fab!(:channel) { Fabricate(:private_category_channel, group: group) }
  fab!(:connection) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: admin,
      forge: "github",
      host: "github.com",
      repo_path: "acme/sim-tools",
      default_branch: "main"
    )
  end

  before do
    SiteSetting.chat_enabled = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    Group.refresh_automatic_group!(:trust_level_0)
    group.add(member)
    channel.add(member)
  end

  it "publishes one shared payload with native channel permissions" do
    messages =
      MessageBus.track_publish("/repo-activity/#{channel.id}") do
        described_class.publish_now(channel)
      end
    expect(messages.size).to eq(1)
    expect(messages.first.group_ids).to include(
      "chat-restricted-category-group-#{group.id}"
    )
    expect(messages.first.data.keys.map(&:to_s)).not_to include(
      "can_manage",
      "new_count",
      "last_seen_event_id"
    )
    expect(messages.to_json).not_to include(
      connection.secret,
      connection.public_id
    )
  end

  it "debounces publication per channel without enumerating users in the request" do
    User.expects(:real).never
    expect do 3.times { described_class.publish(channel) } end.to change {
      Jobs::RepoActivityPublish.jobs.size
    }.by(1)
    connection.events.create!(chat_channel_id: channel.id, kind: "push")
    messages =
      MessageBus.track_publish("/repo-activity/#{channel.id}") do
        Jobs::RepoActivityPublish.new.execute(channel_id: channel.id)
      end
    expect(messages.size).to eq(1)
    expect(messages.first.data[:latest_event_id]).to eq(
      connection.events.maximum(:id)
    )
    expect { described_class.publish(channel) }.to change {
      Jobs::RepoActivityPublish.jobs.size
    }.by(1)
  end

  it "keeps 50 events and prunes only idle non-default branches" do
    55.times do
      connection.events.create!(chat_channel_id: channel.id, kind: "push")
    end
    connection.refs.create!(ref_name: "main", updated_at: 20.days.ago)
    connection.refs.create!(ref_name: "old", updated_at: 20.days.ago)
    connection.refs.create!(ref_name: "recent", updated_at: 1.day.ago)
    connection.refs.create!(
      ref_name: "pr/3",
      kind: "pr",
      updated_at: 20.days.ago
    )
    newest = connection.events.maximum(:id)
    Jobs::RepoActivityPrune.new.execute({})
    expect(connection.events.count).to eq(50)
    expect(DiscourseRepoActivity::Event.pushes_today(connection.id)).to eq(55)
    expect(connection.events.maximum(:id)).to eq(newest)
    expect(connection.refs.pluck(:ref_name)).to contain_exactly(
      "main",
      "recent"
    )
  end
  it "continues pruning subsequent connections when an announcement fails" do
    SiteSetting.repo_activity_enabled = true
    other =
      DiscourseRepoActivity::Connection.create!(
        chat_channel: channel,
        created_by: admin,
        forge: "github",
        host: "github.com",
        repo_path: "acme/other"
      )
    [connection, other].each do |c|
      c.events.create!(
        chat_channel_id: channel.id,
        kind: "issue_opened",
        loud: true
      )
    end
    DiscourseRepoActivity::Announcer
      .any_instance
      .stubs(:announce)
      .raises(StandardError)
    Rails
      .logger
      .expects(:warn)
      .with(regexp_matches(/connection #{connection.id}/))
    Rails.logger.expects(:warn).with(regexp_matches(/connection #{other.id}/))
    expect { Jobs::RepoActivityPrune.new.execute({}) }.not_to raise_error
  end
  def bus_client(user)
    MessageBus::Client.new(
      client_id: "user-#{user.id}",
      user_id: user.id,
      group_ids:
        Chat.message_bus_group_ids_for(
          User.find(user.id).belonging_to_group_ids
        ),
      message_bus: MessageBus
    )
  end

  def receives_payload?(user, message)
    client = bus_client(user)
    client.site_id = RailsMultisite::ConnectionManagement.current_db
    client.subscribe(message.channel, message.message_id - 1)
    client.backlog.any? { |delivered| delivered.channel == message.channel }
  end

  it "filters delivery to current category members and excludes removed members" do
    message =
      MessageBus
        .track_publish("/repo-activity/#{channel.id}") do
          described_class.publish_now(channel)
        end
        .sole
    expect(receives_payload?(member, message)).to eq(true)
    expect(receives_payload?(outsider, message)).to eq(false)
    group.remove(member)
    expect(receives_payload?(member, message)).to eq(false)
  end

  it "filters anonymous clients even when native public chat publication is global" do
    public_channel = Fabricate(:chat_channel)
    SiteSetting.enable_public_channels = true
    SiteSetting.chat_allowed_groups =
      "#{Group::AUTO_GROUPS[:everyone]}|#{Group::AUTO_GROUPS[:anonymous_users]}"
    expect(Chat::Publisher.permissions(public_channel)).to eq({})
    message =
      MessageBus
        .track_publish("/repo-activity/#{public_channel.id}") do
          described_class.publish_now(public_channel)
        end
        .sole
    expect(
      MessageBus::Client.new(
        client_id: "anonymous",
        message_bus: MessageBus
      ).allowed?(message)
    ).to eq(false)
    expect(bus_client(member).allowed?(message)).to eq(true)
  end
end
