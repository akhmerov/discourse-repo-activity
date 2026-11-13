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
    expect(response.parsed_body["channels"][channel.id.to_s]["repos"]).to eq([])
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
