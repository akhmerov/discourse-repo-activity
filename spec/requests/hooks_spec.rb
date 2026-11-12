# frozen_string_literal: true

RSpec.describe DiscourseRepoActivity::HooksController do
  fab!(:admin)
  fab!(:channel, :chat_channel)
  fab!(:connection) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: admin,
      forge: "github",
      host: "github.com",
      repo_path: "acme/sim-tools"
    )
  end

  before do
    SiteSetting.chat_enabled = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    SiteSetting.repo_activity_enabled = true
  end

  def deliver(
    payload = repo_payload("github_push"),
    signature: :valid,
    delivery: SecureRandom.uuid,
    event: "push"
  )
    body = JSON.generate(payload)
    headers = {
      "CONTENT_TYPE" => "application/json",
      "X-GitHub-Event" => event,
      "X-GitHub-Delivery" => delivery
    }
    if signature != :missing
      headers["X-Hub-Signature-256"] = (
        if signature == :valid
          "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", connection.secret, body)
        else
          "sha256=invalid"
        end
      )
    end
    post "/repo-activity/hooks/#{connection.public_id}",
         params: body,
         headers: headers
  end

  it "accepts a signed quiet push without storing its body" do
    expect { deliver }.to change { connection.events.count }.by(1)
    expect(response.status).to eq(200)
    expect(connection.events.last.summary).to include(
      "last_commit" => "Fix solver",
      "commit_count" => 1
    )
    expect(connection.events.last.summary.to_json).not_to include(
      repo_payload("github_push").dig("head_commit", "message")
    )
    expect(Chat::Message.where(chat_channel: channel).count).to eq(0)
    expect(connection.reload.last_delivery_at).to be_present
  end

  it "rejects invalid and missing GitHub signatures" do
    deliver(signature: :invalid)
    expect(response.status).to eq(401)
    deliver(signature: :missing)
    expect(response.status).to eq(401)
    expect(connection.events.count).to eq(0)
  end

  it "deduplicates deliveries for 24 hours" do
    freeze_time
    deliver(delivery: "same-delivery")
    deliver(delivery: "same-delivery")
    expect(connection.events.count).to eq(1)
    key =
      "repo-activity:delivery:#{connection.id}:#{Digest::SHA256.hexdigest("same-delivery")}"
    expect(Discourse.redis.ttl(key)).to be_between(86_390, 86_400)
    Discourse.redis.expire(key, -1)
    deliver(delivery: "same-delivery")
    expect(connection.events.count).to eq(2)
  end

  it "verifies GitLab tokens and deduplicates event UUIDs" do
    connection.update!(
      forge: "gitlab",
      host: "gitlab.tudelft.nl",
      repo_path: "group/nested/sim-tools"
    )
    body = repo_payload("gitlab_push").to_json
    headers = {
      "CONTENT_TYPE" => "application/json",
      "X-Gitlab-Event" => "Push Hook",
      "X-Gitlab-Event-UUID" => "gitlab-uuid"
    }
    post "/repo-activity/hooks/#{connection.public_id}",
         params: body,
         headers: headers
    expect(response.status).to eq(401)
    headers["X-Gitlab-Token"] = "invalid"
    post "/repo-activity/hooks/#{connection.public_id}",
         params: body,
         headers: headers
    expect(response.status).to eq(401)
    headers["X-Gitlab-Token"] = connection.secret
    post "/repo-activity/hooks/#{connection.public_id}",
         params: body,
         headers: headers
    expect(response.status).to eq(200)
    post "/repo-activity/hooks/#{connection.public_id}",
         params: body,
         headers: headers
    expect(connection.events.count).to eq(1)
  end

  it "rejects archived, closed, deleted and disabled channels" do
    channel.update!(status: :archived)
    deliver
    expect(response.status).to eq(404)
    channel.update!(status: :closed)
    deliver
    expect(response.status).to eq(404)
    channel.update!(status: :open, deleted_at: Time.current)
    deliver
    expect(response.status).to eq(404)
    channel.update!(deleted_at: nil)
    connection.update!(enabled: false)
    deliver
    expect(response.status).to eq(404)
    expect(connection.reload.last_delivery_at).to be_nil
    expect(connection.last_delivery_error).to be_nil
    expect(connection.events.count).to eq(0)
  end

  it "ignores unsupported events and actions with 2xx" do
    deliver(event: "ping")
    expect(response.status).to eq(200)
    deliver(
      repo_payload("github_issues").merge("action" => "edited"),
      event: "issues"
    )
    expect(response.status).to eq(200)
    expect(connection.events.count).to eq(0)
  end

  it "enforces event recording toggles" do
    connection.update!(enabled_events: ["release"])
    deliver
    expect(response.status).to eq(200)
    expect(connection.events.count).to eq(0)
    expect(connection.refs.count).to eq(0)
  end

  it "rate limits each connection independently" do
    RateLimiter.enable
    # Spend the allowance through the same public limiter without 120 HTTP requests.
    120.times do
      RateLimiter.new(
        nil,
        "repo-activity:#{connection.id}",
        120,
        1.minute
      ).performed!
    end
    deliver
    expect(response.status).to eq(429)
    expect(connection.events.count).to eq(0)
  end
end
