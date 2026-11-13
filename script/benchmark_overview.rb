# frozen_string_literal: true

# Full Rack requests, including authentication, authorization and serialization;
# benchmark data is rolled back. Does not contact another instance.
unless Rails.env.development? &&
         ActiveRecord::Base.connection_db_config.database.start_with?("repo_activity_")
  abort "Disposable local database required"
end
require "benchmark"
user = User.find_by!(username: "sim_theo_linden")
owner = User.find_by!(username: "sim_mira_vale")
client = ActionDispatch::Integration::Session.new(Rails.application)
client.host! Discourse.current_hostname
client.https!
client.get "/session/#{user.username}/become"
raise "Local login failed: #{client.response.status}" unless client.response.status.in?([200, 302])
results = {}
ActiveRecord::Base.transaction do
  ids =
    30.times.map do |index|
      category =
        Category.create!(name: "Overview benchmark #{index} #{SecureRandom.hex(3)}", user: owner)
      channel = Chat::CategoryChannel.create!(chatable: category, name: category.name)
      2.times do |repo|
        connection =
          DiscourseRepoActivity::Connection.create!(
            chat_channel: channel,
            created_by: owner,
            forge: "github",
            host: "github.com",
            repo_path: "benchmark/project-#{index}-#{repo}",
            default_branch: "main",
          )
        connection.refs.create!(
          ref_name: "main",
          kind: "branch",
          ci_state: repo.zero? ? "failed" : "success",
          head_sha: "a" * 40,
        )
        20.times do |n|
          connection.events.create!(
            chat_channel_id: channel.id,
            kind: n.even? ? "push" : "ci",
            summary: {
              sha: n.to_s.rjust(40, "0"),
            },
          )
        end
      end
      channel.id
    end
  [1, 30].each do |size|
    samples = []
    queries = []
    bytes = nil
    11.times do
      count = 0
      subscription =
        ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
          payload = args.last
          count += 1 if payload[:sql].match?(/\ASELECT/i) && payload[:name] != "SCHEMA" &&
            !payload[:cached]
        end
      begin
        elapsed =
          Benchmark.realtime do
            client.get "/repo-activity/overview.json", params: { channel_ids: ids.first(size) }
          end
        raise "Request failed: #{client.response.status}" unless client.response.status == 200
        data = client.response.parsed_body.fetch("channels")
        unless data.size == size && data.values.sum { |row| row.fetch("repos").length } == size * 2
          raise "Authorization/fixture mismatch"
        end
        samples << elapsed * 1000
        queries << count
        bytes = client.response.body.bytesize
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end
    end
    warm = samples.drop(1).sort
    results[size] = {
      connections: size * 2,
      events: size * 40,
      first_request_ms: samples.first.round(2),
      warm_median_ms: ((warm[4] + warm[5]) / 2).round(2),
      warm_p95_ms: warm[9].round(2),
      warm_samples_ms: samples.drop(1).map { |value| value.round(2) },
      select_queries: queries,
      response_bytes: bytes,
    }
  end
  raise ActiveRecord::Rollback
end
File.write(Rails.root.join("tmp/overview-benchmark.json"), JSON.pretty_generate(results))
puts JSON.pretty_generate(results)
