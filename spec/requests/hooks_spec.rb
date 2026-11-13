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
      repo_path: "acme/sim-tools",
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
      "X-GitHub-Delivery" => delivery,
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
    post "/repo-activity/hooks/#{connection.public_id}", params: body, headers: headers
  end

  it "accepts a signed quiet push without storing its body" do
    expect { deliver }.to change { connection.events.count }.by(1)
    expect(response.status).to eq(200)
    expect(connection.events.last.summary).to include(
      "last_commit" => "Fix solver",
      "commit_count" => 1,
    )
    expect(connection.events.last.summary.to_json).not_to include(
      repo_payload("github_push").dig("head_commit", "message"),
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
    key = "repo-activity:delivery:#{connection.id}:#{Digest::SHA256.hexdigest("same-delivery")}"
    expect(Discourse.redis.ttl(key)).to be_between(86_390, 86_400)
    Discourse.redis.expire(key, -1)
    deliver(delivery: "same-delivery")
    expect(connection.events.count).to eq(2)
  end

  it "verifies GitLab tokens and deduplicates event UUIDs" do
    connection.update!(
      forge: "gitlab",
      host: "gitlab.tudelft.nl",
      repo_path: "group/nested/sim-tools",
    )
    body = repo_payload("gitlab_push").to_json
    headers = {
      "CONTENT_TYPE" => "application/json",
      "X-Gitlab-Event" => "Push Hook",
      "X-Gitlab-Event-UUID" => "gitlab-uuid",
    }
    post "/repo-activity/hooks/#{connection.public_id}", params: body, headers: headers
    expect(response.status).to eq(401)
    headers["X-Gitlab-Token"] = "invalid"
    post "/repo-activity/hooks/#{connection.public_id}", params: body, headers: headers
    expect(response.status).to eq(401)
    headers["X-Gitlab-Token"] = connection.secret
    post "/repo-activity/hooks/#{connection.public_id}", params: body, headers: headers
    expect(response.status).to eq(200)
    post "/repo-activity/hooks/#{connection.public_id}", params: body, headers: headers
    expect(connection.events.count).to eq(1)
    ["Job Hook", "Note Hook", "Wiki Page Hook"].each do |event|
      headers["X-Gitlab-Event"] = event
      headers["X-Gitlab-Event-UUID"] = SecureRandom.uuid
      post "/repo-activity/hooks/#{connection.public_id}", params: body, headers: headers
      expect(response.status).to eq(200)
    end
    expect(connection.management_json["delivery_status"]).to eq("receiving")
    expect(DiscourseRepoActivity::DeliveryStatus.count(connection)).to eq(0)
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
    expect(connection.management_json["delivery_status"]).to eq("paused")
    connection.update!(enabled: true)
    expect(connection.management_json["delivery_status"]).not_to eq("paused")
    expect(connection.events.count).to eq(0)
  end

  it "ignores unsupported events and actions with 2xx" do
    deliver(event: "ping")
    expect(response.status).to eq(200)
    deliver(repo_payload("github_issues").merge("action" => "edited"), event: "issues")
    expect(response.status).to eq(200)
    expect(connection.events.count).to eq(0)
  end

  it "keeps pushes and pipelines quiet under fixed event rules" do
    deliver
    expect(response.status).to eq(200)
    expect(connection.events.count).to eq(1)
    expect(connection.events.sole.loud).to eq(false)
    expect(connection.refs.count).to eq(1)
  end

  it "rate limits each connection independently" do
    RateLimiter.enable
    # Spend the allowance through the same public limiter without 120 HTTP requests.
    120.times { RateLimiter.new(nil, "repo-activity:#{connection.id}", 120, 1.minute).performed! }
    deliver
    expect(response.status).to eq(429)
    expect(connection.events.count).to eq(0)
  end

  it "isolates invalid signatures from authenticated delivery capacity" do
    RateLimiter.enable
    120.times { deliver(signature: :invalid) }
    expect(response.status).to eq(401)
    deliver(signature: :invalid)
    expect(response.status).to eq(429)
    deliver
    expect(response.status).to eq(200)
    expect(connection.events.count).to eq(1)
  end

  it "keeps unauthenticated failures in Redis and protects verified status" do
    freeze_time
    3.times { deliver(signature: :invalid) }
    expect(connection.reload.delivery_status).to eq("waiting")
    expect(connection.status_written_at).to be_nil
    expect(connection.last_delivery_error).to be_nil
    expect(connection.management_json["delivery_status"]).to eq("wrong_secret")
    expect(DiscourseRepoActivity::DeliveryStatus.count(connection)).to eq(3)
    deliver
    written = connection.reload.status_written_at
    4.times do
      deliver(signature: :missing)
      deliver(signature: :invalid)
    end
    expect(connection.reload.delivery_status).to eq("receiving")
    expect(connection.status_written_at).to eq_time(written)
    expect(connection.management_json["delivery_status"]).to eq("receiving")
    expect(DiscourseRepoActivity::DeliveryStatus.count(connection)).to eq(0)
  end

  it "throttles writes and publications even when authenticated status changes" do
    freeze_time
    allow(DiscourseRepoActivity::DeliveryStatus).to receive(:publish)
    deliver(event: "workflow_job")
    first = connection.reload.status_written_at
    deliver({ "hook" => "malformed" }, event: "ping")
    expect(response.status).to eq(400)
    deliver(event: "check_run")
    expect(connection.reload.delivery_status).to eq("receiving")
    expect(connection.status_written_at).to eq_time(first)
    expect(connection.rejected_deliveries).to eq(0)
    expect(connection.management_json["delivery_status"]).to eq("receiving")
    expect(DiscourseRepoActivity::DeliveryStatus).to have_received(:publish).with(channel).once
    freeze_time 61.seconds.from_now
    allow(DiscourseRepoActivity::DeliveryStatus).to receive(:publish)
    deliver(event: "status")
    expect(connection.reload.status_written_at).to be > first
  end

  it "verifies the raw GitHub form envelope before decoding its payload" do
    payload = repo_payload("github_push")
    body = URI.encode_www_form(payload: JSON.generate(payload))
    headers = {
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      "X-GitHub-Event" => "push",
      "X-GitHub-Delivery" => SecureRandom.uuid,
      "X-Hub-Signature-256" =>
        "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", connection.secret, body),
    }
    post "/repo-activity/hooks/#{connection.public_id}", params: body, headers: headers
    expect(response.status).to eq(200)
    expect(connection.events.count).to eq(1)
    headers["X-GitHub-Delivery"] = SecureRandom.uuid
    headers["X-Hub-Signature-256"] = "sha256=" +
      OpenSSL::HMAC.hexdigest("SHA256", connection.secret, JSON.generate(payload))
    post "/repo-activity/hooks/#{connection.public_id}", params: body, headers: headers
    expect(response.status).to eq(401)
  end

  it "records allowlisted ping event warnings without adding activity" do
    deliver({ "hook" => "not an object" }, event: "ping")
    expect(response.status).to eq(400)
    expect(connection.reload.delivery_status).to eq("invalid_payload")
    deliver({ "hook" => { "events" => %w[push issues attacker-provided-text] } }, event: "ping")
    expect(connection.management_json["delivery_status"]).to eq("receiving")
    expect(connection.management_json["missing_hook_events"]).to eq(
      %w[workflow_run pull_request release],
    )
    expect(connection.events).to be_empty
    deliver({ "hook" => { "events" => ["*"] } }, event: "ping")
    expect(connection.management_json["missing_hook_events"]).to eq([])
  end

  it "accepts a first GitLab push of older work and updates the ref" do
    connection.update!(
      forge: "gitlab",
      host: "gitlab.tudelft.nl",
      repo_path: "group/nested/sim-tools",
    )
    payload = repo_payload("gitlab_push")
    payload["commits"].each { |commit| commit["timestamp"] = 2.days.ago.iso8601 }
    headers = {
      "CONTENT_TYPE" => "application/json",
      "X-Gitlab-Event" => "Push Hook",
      "X-Gitlab-Token" => connection.secret,
      "X-Gitlab-Event-UUID" => SecureRandom.uuid,
    }
    post "/repo-activity/hooks/#{connection.public_id}",
         params: JSON.generate(payload),
         headers: headers
    expect(response.status).to eq(200)
    expect(connection.reload.delivery_status).to eq("receiving")
    expect(connection.events.count).to eq(1)
    expect(connection.refs.count).to eq(1)
    payload["commits"].each { |commit| commit["timestamp"] = Time.current.iso8601 }
    headers["X-Gitlab-Event-UUID"] = SecureRandom.uuid
    post "/repo-activity/hooks/#{connection.public_id}",
         params: JSON.generate(payload),
         headers: headers
    expect(response.status).to eq(200)
    expect(connection.events.count).to eq(2)
    expect(Chat::Message.where(chat_channel: channel).count).to eq(0)
  end

  it "stores reason codes instead of malformed payload content" do
    body = "not-json-private-content"
    headers = {
      "CONTENT_TYPE" => "application/json",
      "X-GitHub-Event" => "push",
      "X-GitHub-Delivery" => SecureRandom.uuid,
      "X-Hub-Signature-256" =>
        "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", connection.secret, body),
    }
    post "/repo-activity/hooks/#{connection.public_id}", params: body, headers: headers
    expect(response.status).to eq(400)
    expect(connection.reload.last_delivery_error).to eq("invalid_payload")
    expect(connection.last_delivery_error_at).to be_present
    expect(connection.attributes.to_json.include?(body)).to eq(false)
    failure_at = connection.last_delivery_error_at
    deliver(event: "unknown-event")
    expect(connection.management_json["delivery_status"]).to eq("receiving")
    expect(connection.management_json["last_delivery_error"]).to eq("invalid_payload")
    freeze_time 61.seconds.from_now
    Jobs::RepoActivityDeliveryStatus.new.execute(connection_id: connection.id)
    expect(connection.reload.delivery_status).to eq("receiving")
    expect(connection.last_delivery_error_at).to eq_time(failure_at)
  end

  it "coalesces successful delivery timestamp writes within a minute" do
    freeze_time
    deliver(event: "ping")
    first = connection.reload.last_delivery_at
    freeze_time 10.seconds.from_now
    deliver(event: "ping")
    expect(connection.reload.last_delivery_at).to eq_time(first)
    freeze_time 61.seconds.from_now
    deliver(event: "ping")
    expect(connection.reload.last_delivery_at).to be > first
  end

  it "records recently received allowlisted types and always announces optional events" do
    deliver
    deliver(repo_payload("github_issues"), event: "issues")
    deliver(repo_payload("github_pull_request"), event: "pull_request")
    expect(connection.management_json["recent_event_types"]).to contain_exactly(
      "push",
      "issue",
      "pull_request",
    )
    expect(connection.events.where(kind: %w[issue_opened pr_opened], loud: true).count).to eq(2)
    DiscourseRepoActivity::DeliveryStatus.clear(connection)
    connection.update_columns(
      received_event_types: {
        "push" => 8.days.ago.iso8601,
        "pipeline" => Time.current.iso8601,
      },
    )
    expect(connection.management_json[:recent_event_types]).to eq(["pipeline"])
  end

  it "clears ping warnings on actual events without waiting for another ping" do
    deliver({ "hook" => { "events" => ["push"] } }, event: "ping")
    deliver(repo_payload("github_workflow_run"), event: "workflow_run")
    deliver(repo_payload("github_issues"), event: "issues")
    expect(connection.management_json["missing_hook_events"]).to eq(%w[pull_request release])
    expect(connection.reload.missing_hook_events).to include("workflow_run")
  end

  it "persists coalesced warnings without requiring another delivery" do
    freeze_time
    deliver({ "hook" => { "events" => ["push"] } }, event: "ping")
    deliver(repo_payload("github_workflow_run"), event: "workflow_run")
    delivery_at = connection.management_json["last_delivery_at"]
    freeze_time 61.seconds.from_now
    Jobs::RepoActivityDeliveryStatus.new.execute(connection_id: connection.id)
    expect(connection.reload.missing_hook_events).to eq(%w[pull_request issues release])
    expect(connection.last_delivery_at).to eq_time(Time.iso8601(delivery_at))
  end

  it "accepts extra forge events without a rejection or database status write" do
    freeze_time
    deliver
    written = connection.reload.status_written_at
    %w[workflow_job check_run check_suite status].each { |event| deliver(event: event) }
    expect(connection.reload.status_written_at).to eq_time(written)
    expect(connection.management_json["delivery_status"]).to eq("receiving")
    expect(DiscourseRepoActivity::DeliveryStatus.count(connection)).to eq(0)
  end
end

RSpec.describe "Webhook parameter privacy", type: :request do
  it "suppresses JSON and form parameters before the standard LogSubscriber logs them" do
    SiteSetting.repo_activity_enabled = true
    output = StringIO.new
    subscriber = ActionController::LogSubscriber.new
    allow(subscriber).to receive(:logger).and_return(ActiveSupport::Logger.new(output))
    listener =
      ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*args|
        subscriber.start_processing(ActiveSupport::Notifications::Event.new(*args))
      end
    begin
      %w[application/json application/x-www-form-urlencoded].each do |content_type|
        body =
          (
            if content_type == "application/json"
              { arbitrary_private_key: "private-commit-email-marker" }.to_json
            else
              URI.encode_www_form(payload: "private-commit-email-marker")
            end
          )
        post "/repo-activity/hooks/nonexistent",
             params: body,
             headers: {
               "CONTENT_TYPE" => content_type,
             }
      end
      post "/repo-activity/hooks/nonexistent",
           params: "malformed-private-commit-email-marker",
           headers: {
             "CONTENT_TYPE" => "application/json",
           }
      expect(response.status).to eq(404)
      expect(output.string).to include(
        "Processing by DiscourseRepoActivity::HooksController#create",
      )
      expect(output.string).not_to include(
        "Parameters:",
        "private-commit-email-marker",
        "arbitrary_private_key",
      )
    ensure
      ActiveSupport::Notifications.unsubscribe(listener)
    end
  end
end
