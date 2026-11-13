# frozen_string_literal: true

require "net/http"

unless Rails.env.development? &&
         ActiveRecord::Base.connection_db_config.database.start_with?("repo_activity_")
  abort "Disposable development database required"
end

mode = ARGV.first || "seed"
owner = User.find_by!(username: "sim_mira_vale")
workspace = Category.find_by!(slug: "aurora-research-lab")
category =
  workspace.subcategories.find_by(name: "Repository setup") ||
    DiscourseWorkspaceGroups::CreateChannel.new(
      workspace: workspace,
      user: owner,
      name: "Repository setup",
      description: "Disposable webhook setup examples",
      visibility: "public",
    ).call
channel = Chat::Channel.find_by!(chatable: category)
channel.add(owner)
repos =
  [
    %w[github github.com aurora/lab-handbook],
    %w[gitlab gitlab.tudelft.nl qt/mesh-tools],
    %w[github github.com aurora/transport-sim],
    %w[github github.com aurora/legacy-notes],
  ].map do |forge, host, path|
    DiscourseRepoActivity::Connection.find_or_create_by!(
      chat_channel: channel,
      host: host,
      repo_path: path,
    ) do |connection|
      connection.created_by = owner
      connection.forge = forge
    end
  end

if mode == "seed"
  repos.first.update!(
    received_event_types: {
      push: Time.current.iso8601,
      pipeline: Time.current.iso8601,
      issue: Time.current.iso8601,
    },
  )
  DiscourseRepoActivity::DeliveryStatus.record(repos.first, "receiving")
  if DiscourseRepoActivity::DeliveryStatus.count(repos[1]).zero?
    3.times { DiscourseRepoActivity::DeliveryStatus.record(repos[1], "wrong_secret") }
  end
  repos[2].update!(delivery_status: "waiting", missing_hook_events: [])
  repos[3].update!(enabled: false)
elsif %w[connected warnings rejected].include?(mode)
  body = JSON.generate(hook: { events: mode == "warnings" ? ["push"] : %w[push workflow_run] })
  request = Net::HTTP::Post.new("/repo-activity/hooks/#{repos[2].public_id}")
  request["Content-Type"] = "application/json"
  request["X-GitHub-Event"] = "ping"
  request["X-GitHub-Delivery"] = SecureRandom.uuid
  request["X-Hub-Signature-256"] = (
    if mode == "rejected"
      "sha256=invalid"
    else
      "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", repos[2].secret, body)
    end
  )
  request.body = body
  response = Net::HTTP.start("127.0.0.1", 3000) { |http| http.request(request) }
  raise "Local ping failed" unless response.code == (mode == "rejected" ? "401" : "200")
else
  abort "Unknown fixture mode"
end
metadata = {
  channel_id: channel.id,
  path: URI(channel.url).path,
  github_id: repos[0].id,
  gitlab_id: repos[1].id,
  waiting_id: repos[2].id,
}
File.write(Rails.root.join("tmp/repositories-demo.json"), JSON.pretty_generate(metadata))
puts JSON.generate(metadata)
