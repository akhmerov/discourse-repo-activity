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
      default_branch: "main",
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
    expect(messages.first.group_ids).to include("chat-restricted-category-group-#{group.id}")
    expect(messages.first.data.keys.map(&:to_s)).not_to include(
      "can_manage",
      "new_count",
      "last_seen_event_id",
    )
    expect(messages.to_json).not_to include(connection.secret, connection.public_id)
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
    expect(messages.first.data[:latest_event_id]).to eq(connection.events.maximum(:id))
    expect { described_class.publish(channel) }.to change {
      Jobs::RepoActivityPublish.jobs.size
    }.by(1)
  end

  it "keeps fourteen days and at most 500 commits and prunes only idle non-default branches" do
    505.times do
      connection.events.create!(
        chat_channel_id: channel.id,
        kind: "push",
        summary: {
          commits: [{ sha: "a" * 40 }],
        },
      )
    end
    connection.refs.create!(ref_name: "main", updated_at: 20.days.ago)
    connection.refs.create!(ref_name: "old", updated_at: 20.days.ago)
    connection.refs.create!(ref_name: "recent", updated_at: 1.day.ago)
    connection.refs.create!(ref_name: "pr/3", kind: "pr", updated_at: 20.days.ago)
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "issue_opened",
      created_at: 15.days.ago,
    )
    newest = connection.events.where(kind: "push").maximum(:id)
    Jobs::RepoActivityPrune.new.execute({})
    expect(connection.events.count).to eq(500)
    expect(DiscourseRepoActivity::Event.pushes_today(connection.id)).to eq(505)
    expect(connection.events.maximum(:id)).to eq(newest)
    expect(connection.refs.pluck(:ref_name)).to contain_exactly("main", "recent")
  end

  it "continues pruning subsequent connections when an announcement fails" do
    SiteSetting.repo_activity_enabled = true
    other =
      DiscourseRepoActivity::Connection.create!(
        chat_channel: channel,
        created_by: admin,
        forge: "github",
        host: "github.com",
        repo_path: "acme/other",
      )
    [connection, other].each do |c|
      c.events.create!(chat_channel_id: channel.id, kind: "issue_opened", loud: true)
    end
    DiscourseRepoActivity::Announcer.any_instance.stubs(:announce).raises(StandardError)
    Rails.logger.expects(:warn).with(regexp_matches(/connection #{connection.id}/))
    Rails.logger.expects(:warn).with(regexp_matches(/connection #{other.id}/))
    expect { Jobs::RepoActivityPrune.new.execute({}) }.not_to raise_error
  end

  def bus_client(user)
    MessageBus::Client.new(
      client_id: "user-#{user.id}",
      user_id: user.id,
      group_ids: Chat.message_bus_group_ids_for(User.find(user.id).belonging_to_group_ids),
      message_bus: MessageBus,
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
        .track_publish("/repo-activity/#{channel.id}") { described_class.publish_now(channel) }
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
      MessageBus::Client.new(client_id: "anonymous", message_bus: MessageBus).allowed?(message),
    ).to eq(false)
    expect(bus_client(member).allowed?(message)).to eq(true)
  end

  it "publishes nothing when the public-channel fallback has no groups" do
    public_channel = Fabricate(:chat_channel)
    allow(Chat::Publisher).to receive(:permissions).and_return({})
    if Chat.respond_to?(:message_bus_allowed_group_ids)
      allow(Chat).to receive(:message_bus_allowed_group_ids).and_return([])
    end
    messages =
      MessageBus.track_publish("/repo-activity/#{public_channel.id}") do
        described_class.publish_now(public_channel)
      end
    expect(messages).to be_empty
  end

  it "paginates a bounded stream across repositories and excludes quiet CI deliveries" do
    35.times do |i|
      connection.events.create!(
        chat_channel_id: channel.id,
        kind: "push",
        summary: {
          title: "push #{i}",
        },
      )
    end
    connection.events.create!(chat_channel_id: channel.id, kind: "ci")
    first = described_class.for(channel, member)
    expect(first[:stream].size).to eq(30)
    expect(first[:new_count]).to eq(35)
    expect(first[:repos].sole[:new_count]).to eq(35)
    expect(first[:latest_event_id]).to eq(connection.events.visible.maximum(:id))
    expect(first[:stream].map { |e| e["kind"] }.uniq).to eq(["push"])
    expect(first[:repos].first).not_to have_key(:refs)
    expect(first[:repos].first).not_to have_key(:events)
    second = described_class.stream(channel, before: first[:earlier_before])
    expect(second[:stream].size).to eq(5)
    expect(second[:earlier_before]).to be_nil
    expect(first[:stream].map { |e| e["id"] } & second[:stream].map { |e| e["id"] }).to be_empty
    payload =
      MessageBus
        .track_publish("/repo-activity/#{channel.id}") { described_class.publish_now(channel) }
        .sole
        .data
    expect(payload).to include(
      refresh: true,
      latest_event_id: connection.events.visible.maximum(:id),
    )
    expect(payload).not_to have_key(:stream)
    expect(payload).not_to have_key(:event_ids)
  end

  it "does not label a quiet repo idle because a noisy repo filled the stream window" do
    quiet = connection.events.create!(chat_channel_id: channel.id, kind: "push")
    other = connection.dup
    other.repo_path = "acme/noisy"
    other.public_id = SecureRandom.hex(20)
    other.save!
    45.times { other.events.create!(chat_channel_id: channel.id, kind: "push") }
    data = described_class.for(channel, member)
    expect(data[:repos].find { |r| r[:id] == connection.id }[:last_activity_at]).to eq(
      quiet.created_at,
    )
    expect(
      described_class.stream(channel, connection_id: connection.id)[:stream].map { |e| e["id"] },
    ).to eq([quiet.id])
  end

  it "caps stored commits rather than just counting push events" do
    30.times do
      connection.events.create!(
        chat_channel_id: channel.id,
        kind: "push",
        summary: {
          commits: Array.new(20) { { sha: "a" * 40 } },
        },
      )
    end
    Jobs::RepoActivityPrune.new.execute({})
    expect(connection.events.count).to eq(25)
  end

  it "leaves ordinary chat messages and replies independent of the repository bot" do
    DiscourseRepoActivity::Bot.expects(:user).never
    message = Fabricate(:chat_message, chat_channel: channel, user: member)
    reply =
      Fabricate(:chat_message, chat_channel: channel, user: member, in_reply_to_id: message.id)
    expect {
      DiscourseEvent.trigger(:chat_message_created, message, channel, member, {})
    }.not_to raise_error
    expect {
      DiscourseEvent.trigger(:chat_message_created, reply, channel, member, {})
    }.not_to raise_error
  end

  it "shows a recovery once, on its push, and uses the same filter for counts" do
    push =
      connection.events.create!(
        chat_channel_id: channel.id,
        kind: "push",
        summary: {
          sha: "a" * 40,
          ci_state: "success",
        },
      )
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "recovery",
      summary: {
        sha: "a" * 40,
      },
    )
    connection.events.create!(chat_channel_id: channel.id, kind: "ci")
    data = described_class.for(channel, member)
    expect(data[:stream].map { |event| event["id"] }).to eq([push.id])
    expect(data[:new_count]).to eq(1)
    expect(data[:latest_event_id]).to eq(push.id)
    push.destroy!
    expect(described_class.for(channel, member)[:stream].map { |event| event["kind"] }).to eq(
      ["recovery"],
    )
  end

  it "indexes message lookups" do
    expect(
      ActiveRecord::Base.connection.index_exists?(:repo_activity_events, :chat_message_id),
    ).to eq(true)
  end

  it "acknowledges the newest item from the returned visible page" do
    connection.events.create!(chat_channel_id: channel.id, kind: "push")
    original = described_class.method(:stream)
    allow(described_class).to receive(:stream) do |*args, **kwargs|
      connection.events.create!(chat_channel_id: channel.id, kind: "push")
      original.call(*args, **kwargs)
    end
    data = described_class.for(channel, member)
    expect(data[:latest_event_id]).to eq(data[:stream].first.fetch("id"))
  end
end
