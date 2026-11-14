# frozen_string_literal: true

RSpec.describe DiscourseRepoActivity::OverviewController do
  fab!(:user)
  fab!(:channel, :chat_channel)
  fab!(:connection) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: user,
      forge: "github",
      host: "github.com",
      repo_path: "acme/solver",
    )
  end
  before do
    SiteSetting.chat_enabled = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    SiteSetting.repo_activity_enabled = true
    sign_in(user)
  end

  def event(kind, sha = "a" * 40)
    connection.events.create!(chat_channel_id: channel.id, kind: kind, summary: { sha: sha })
  end
  it "uses the header's visible-event cursor, excludes quiet CI and duplicate recovery, and exposes no diagnostics" do
    first = event("push")
    event("ci")
    event("recovery")
    event("pr_opened")
    get "/repo-activity/overview.json", params: { channel_ids: [channel.id] }
    expect(response.headers["Cache-Control"]).to include("no-store")
    row = response.parsed_body.fetch("channels").fetch(channel.id.to_s)
    expect(row["new_count"]).to eq(2)
    expect(row["new_count"]).to eq(DiscourseRepoActivity::Snapshot.for(channel, user)[:new_count])
    expect(row["repos"].sole).to include("name" => "solver", "state" => "none")
    expect(response.body).not_to include("secret", "delivery_status", "webhook_url", "actor_login")
    put "/repo-activity/channels/#{channel.id}/read.json", params: { last_seen_event_id: first.id }
    get "/repo-activity/overview.json", params: { channel_ids: [channel.id] }
    expect(response.parsed_body["channels"][channel.id.to_s]["new_count"]).to eq(1)
    connection.update!(enabled: false)
    get "/repo-activity/overview.json", params: { channel_ids: [channel.id] }
    expect(response.parsed_body["channels"][channel.id.to_s]["repos"].sole["state"]).to eq("paused")
  end

  it "shares duplicate names and release deduplication across overview, snapshot and paginated streams" do
    other =
      DiscourseRepoActivity::Connection.create!(
        chat_channel: channel,
        created_by: user,
        forge: "gitlab",
        host: "gitlab.example.org",
        repo_path: "research/solver",
      )
    tag =
      connection.events.create!(chat_channel_id: channel.id, kind: "tag", summary: { tag: "v1.0" })
    foreign_tag =
      other.events.create!(chat_channel_id: channel.id, kind: "tag", summary: { tag: "v1.0" })
    release =
      connection.events.create!(
        chat_channel_id: channel.id,
        kind: "release",
        summary: {
          tag: "v1.0",
        },
      )
    # A release outside this page must still hide its tag on earlier/filtered pages.
    get "/repo-activity/channels/#{channel.id}.json",
        params: {
          before: release.id,
          connection_id: connection.id,
        }
    expect(response.parsed_body["stream"]).to be_empty
    get "/repo-activity/channels/#{channel.id}.json"
    snapshot = response.parsed_body
    expect(snapshot["stream"].map { |e| e["id"] }).to eq([release.id, foreign_tag.id])
    expect(snapshot["new_count"]).to eq(2)
    expect(snapshot["repos"].to_h { |r| [r["id"], r["display_name"]] }).to eq(
      connection.id => "acme/solver",
      other.id => "research/solver",
    )
    expect(snapshot["repos"].map { |r| r["forge"] }).to contain_exactly("github", "gitlab")
    get "/repo-activity/overview.json", params: { channel_ids: [channel.id] }
    row = response.parsed_body["channels"][channel.id.to_s]
    expect(row["new_count"]).to eq(2)
    expect(row["repos"].map { |r| r["name"] }).to contain_exactly("acme/solver", "research/solver")
    put "/repo-activity/channels/#{channel.id}/read.json",
        params: {
          last_seen_event_id: release.id,
        }
    get "/repo-activity/channels/#{channel.id}.json"
    expect(response.parsed_body["new_count"]).to eq(0)
    expect(response.parsed_body["last_seen_event_id"]).to eq(release.id)
    expect(tag.id).to be < release.id
  end

  it "returns the bus cursor captured before reading the snapshot" do
    old_id = MessageBus.publish("/repo-activity/#{channel.id}", { refresh: true })
    cursor = MessageBus.last_id("/repo-activity/#{channel.id}")
    get "/repo-activity/overview.json", params: { channel_ids: [channel.id] }
    expect(response.parsed_body["channels"][channel.id.to_s]["message_bus_last_id"]).to eq(cursor)
    expect(old_id).to be_present
  end

  it "includes paused failing repositories without treating them as failures" do
    connection.update!(enabled: false, default_branch: "main")
    connection.refs.create!(
      ref_name: "main",
      kind: "branch",
      ci_state: "failed",
      head_sha: "a" * 40,
    )
    event("push")
    get "/repo-activity/overview.json", params: { channel_ids: [channel.id] }
    row = response.parsed_body["channels"][channel.id.to_s]
    expect(row["repos"].sole["state"]).to eq("paused")
    expect(row["new_count"]).to eq(1)
    snapshot = DiscourseRepoActivity::Snapshot.for(channel, user)
    expect(snapshot[:repos].sole[:failing]).to eq(false)
    expect(snapshot[:repos].sole[:state]).to eq("paused")
    expect(snapshot[:new_count]).to eq(1)
  end

  it "includes readable read-only and closed channels like the header" do
    %i[read_only closed].each do |status|
      channel.update!(status: status)
      expect(DiscourseRepoActivity.can_view?(channel, user)).to eq(true)
      get "/repo-activity/overview.json", params: { channel_ids: [channel.id] }
      expect(response.parsed_body["channels"].keys).to eq([channel.id.to_s])
    end
  end

  it "authorizes every channel including mixed public/private requests" do
    group = Fabricate(:group)
    category = Fabricate(:private_category, group: group)
    private_channel = Fabricate(:chat_channel, chatable: category)
    private_connection =
      DiscourseRepoActivity::Connection.create!(
        chat_channel: private_channel,
        created_by: user,
        forge: "github",
        host: "github.com",
        repo_path: "private/hidden",
      )
    get "/repo-activity/overview.json", params: { channel_ids: [channel.id, private_channel.id] }
    expect(response.parsed_body["channels"].keys).to eq([channel.id.to_s])
    expect(response.body).not_to include(private_connection.repo_path, "hidden")
    group.add(user)
    get "/repo-activity/overview.json", params: { channel_ids: [private_channel.id] }
    expect(response.parsed_body["channels"].keys).to eq([private_channel.id.to_s])
  end

  it "requires login and bounds/validates the requested IDs" do
    get "/repo-activity/overview.json", params: { channel_ids: ["1) OR true"] }
    expect(response.status).to eq(400)
    get "/repo-activity/overview.json", params: { channel_ids: (1..201).to_a }
    expect(response.status).to eq(400)
    get "/repo-activity/overview.json", params: { channel_ids: { bad: "1" } }
    expect(response.status).to eq(400)
    reset!
    get "/repo-activity/overview.json", params: { channel_ids: [channel.id] }
    expect(response.status).to eq(403)
  end

  it "bounds database queries for 30 channels and 60 connections" do
    channels = Array.new(30) { Fabricate(:chat_channel) }
    channels.each_with_index do |item, index|
      2.times do |repo|
        c =
          DiscourseRepoActivity::Connection.create!(
            chat_channel: item,
            created_by: user,
            forge: "github",
            host: "github.com",
            repo_path: "acme/project-#{index}-#{repo}",
            default_branch: "main",
          )
        c.refs.create!(
          ref_name: "main",
          kind: "branch",
          head_sha: "a" * 40,
          ci_state: repo.zero? ? "failed" : "success",
        )
        c.events.create!(chat_channel_id: item.id, kind: "push", summary: {})
      end
    end
    queries = []
    subscription =
      ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        payload = args.last
        queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) && payload[:name] != "SCHEMA"
      end
    begin
      result = DiscourseRepoActivity::Overview.for(channels.map(&:id), user)
      expect(result.size).to eq(30)
      expect(result.values.sum { |row| row[:repos].size }).to eq(60)
      expect(result.values.first[:repos].map { |repo| repo[:state] }).to eq(%w[failed success])
      expect(queries.length).to be <= 12
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end
end
