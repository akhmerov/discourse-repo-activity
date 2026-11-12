# frozen_string_literal: true

# Run with bin/rails runner, in an explicitly named disposable development DB.
require "net/http"
require "optparse"
$stdout.sync = true

unless Rails.env.development? &&
         ActiveRecord::Base.connection_db_config.database.start_with?("repo_activity_")
  abort "Simulation requires a disposable development database"
end

options = { mode: "seed", url: "http://127.0.0.1:3000" }
OptionParser
  .new do |p|
    p.on("--mode MODE", %w[seed week report reset metrics-reset edges incident]) do |v|
      options[:mode] = v
    end
    p.on("--url URL") { |v| options[:url] = v }
  end
  .parse!(ARGV)
uri = URI(options[:url])
unless %w[127.0.0.1 localhost].include?(uri.host) && uri.scheme == "http"
  abort "Only local HTTP destinations are allowed"
end

module RepoActivitySimulation
  extend self
  PREFIX = "sim_"
  NAMES = [
    "Mira Vale",
    "Theo Linden",
    "Nora Finch",
    "Eli Rowan",
    "Sana Brook",
    "Owen Moss",
    "Lena Reed",
    "Ivo Marsh",
  ].freeze
  CHANNELS = {
    "Engineering" => 5,
    "Analysis" => 3,
    "Instruments" => 2,
    "Releases" => 1,
    "Operations" => 1,
    "Documentation" => 1,
    "Archive" => 1,
    "Planning" => 1,
  }.freeze

  def users(count)
    (0...count).map do |i|
      username = "#{PREFIX}#{i < NAMES.length ? NAMES[i].downcase.tr(" ", "_") : "member_#{i}"}"
      User.find_by(username: username) ||
        User.create!(
          username: username,
          name: i < NAMES.length ? NAMES[i] : "Lab member #{i}",
          email: "#{username}@example.invalid",
          password: SecureRandom.hex(24),
          active: true,
          approved: true,
          trust_level: 2,
          admin: i.zero?,
        )
    end
  end

  def seed
    SiteSetting.chat_enabled = true
    SiteSetting.repo_activity_enabled = true
    SiteSetting.discourse_workspace_groups_enabled = true
    SiteSetting.navigation_menu = "sidebar"
    DiscourseRepoActivity::Bot.ensure!
    people = users(40)
    owner = people.first
    workspace =
      Category.find_by(name: "Aurora Research Lab") ||
        Category.create!(
          name: "Aurora Research Lab",
          user: owner,
          color: "0088CC",
          text_color: "FFFFFF",
        )
    unless workspace.workspace_root?
      DiscourseWorkspaceGroups::EnsureWorkspace.new(
        category: workspace,
        user: owner,
        public_read: true,
      ).call
    end
    people.each do |u|
      workspace.workspace_group.add(u) unless workspace.workspace_group.users.exists?(id: u.id)
    end
    CHANNELS.each_with_index do |(name, count), ci|
      cat =
        workspace.subcategories.find_by(name: name) ||
          DiscourseWorkspaceGroups::CreateChannel.new(
            workspace: workspace,
            user: owner,
            name: name,
            description: "Aurora lab #{name.downcase} discussions",
            visibility: %w[Operations Planning].include?(name) ? "private" : "public",
          ).call
      channel = Chat::Channel.find_by!(chatable: cat)
      people
        .first(40)
        .each do |u|
          cat.workspace_group.add(u) unless cat.workspace_group.users.exists?(id: u.id)
          channel.add(u) unless channel.user_chat_channel_memberships.exists?(user_id: u.id)
        end
      count.times do |ri|
        forge = (ci + ri).even? ? "github" : "gitlab"
        path = "aurora/#{name.downcase}-#{ri + 1}"
        DiscourseRepoActivity::Connection.find_or_create_by!(
          chat_channel: channel,
          repo_path: path,
        ) do |c|
          c.created_by = owner
          c.forge = forge
          c.host = forge == "github" ? "github.com" : "git.aurora.example"
          c.default_branch = "main"
        end
      end
      if channel.chat_messages.where(user_id: people.map(&:id)).empty?
        [
          "Morning! The new calibration data is ready for review.",
          "Thanks, I will compare it with yesterday's baseline after lunch.",
          "The drift looks smaller now. I added the notes to the analysis branch.",
          "Could someone review the uncertainty estimates before we cut the release?",
          "I checked the plots; the error bars now agree with the bootstrap.",
          "Great. Let's keep the last stable build available for the instrument team.",
        ].each_with_index do |text, i|
          message =
            Chat::Message.create!(
              chat_channel: channel,
              user: people[i],
              message: text,
              created_at: (6 - i).hours.ago,
            )
          message.cook
          message.save!
          channel.update!(last_message: message)
        end
      end
    end
    Chat::Message
      .where(user_id: people.first(40).map(&:id))
      .uncooked
      .find_each do |message|
        message.cook
        message.save!
      end
    puts({ seeded_users: people.size, connections: connections.count }.to_json)
  end

  def connections
    DiscourseRepoActivity::Connection.where(
      created_by: User.find_by!(username: "sim_mira_vale"),
    ).order(:id)
  end

  def payload(c, kind, n, state: "success", pr: false)
    sha = Digest::SHA1.hexdigest("#{c.id}:#{n}")
    actor = "sim_#{NAMES[n % NAMES.length].downcase.tr(" ", "_")}"
    url = c.repository_url
    title =
      [
        "Improve calibration precision",
        "Reduce solver memory use",
        "Document acquisition protocol",
        "Fix parallel reduction race",
      ][
        n % 4
      ]
    if c.forge == "github"
      data = {
        repository: {
          id: c.id,
          full_name: c.repo_path,
          name: c.display_name,
          html_url: url,
          default_branch: "main",
          private: c.chat_channel.chatable.read_restricted?,
        },
        sender: {
          login: actor,
        },
      }
      event = kind
      case kind
      when "push"
        data.merge!(
          ref: "refs/heads/main",
          before: Digest::SHA1.hexdigest("before#{n}"),
          after: sha,
          forced: n % 30 == 0,
          deleted: false,
          compare: "#{url}/compare/base...#{sha}",
          pusher: {
            name: actor,
          },
          commits: [{ id: sha, message: title, timestamp: (7.days.ago + n.minutes).iso8601 }],
          head_commit: {
            id: sha,
            message: title,
          },
        )
      when "workflow_run"
        workflow = n % 3 + 1
        data.merge!(
          action: "completed",
          workflow_run: {
            id: n * 10 + workflow,
            workflow_id: workflow,
            name: %w[Tests Lint Build][workflow - 1],
            run_attempt: 1,
            status: "completed",
            conclusion: state == "failed" ? "failure" : "success",
            head_branch: pr ? "main" : "main",
            head_sha: sha,
            event: pr ? "pull_request" : "push",
            html_url: "#{url}/actions/runs/#{n}",
            head_repository: {
              id: pr ? c.id + 10_000 : c.id,
            },
            actor: {
              login: actor,
            },
            pull_requests: pr ? [{ number: n, base: { repo: { id: c.id } } }] : [],
          },
        )
      when "pull_request"
        data.merge!(
          action: pr ? "closed" : "opened",
          number: n,
          pull_request: {
            number: n,
            title: title,
            html_url: "#{url}/pull/#{n}",
            merged: pr,
            head: {
              sha: sha,
              ref: "feature/calibration",
              repo: {
                id: c.id + 10_000,
              },
            },
            base: {
              ref: "main",
              repo: {
                id: c.id,
              },
            },
          },
        )
      when "issues"
        data.merge!(
          action: "opened",
          issue: {
            number: n,
            title: title,
            html_url: "#{url}/issues/#{n}",
          },
        )
      when "release"
        data.merge!(
          action: "published",
          release: {
            name: "Aurora v#{n}.0",
            tag_name: "v#{n}.0",
            html_url: "#{url}/releases/tag/v#{n}.0",
          },
        )
      end
    else
      data = {
        project: {
          id: c.id,
          path_with_namespace: c.repo_path,
          web_url: url,
          default_branch: "main",
        },
        user: {
          username: actor,
        },
        user_username: actor,
      }
      case kind
      when "push"
        event = "Push Hook"
        data.merge!(
          object_kind: "push",
          ref: "refs/heads/main",
          before: Digest::SHA1.hexdigest("before#{n}"),
          after: sha,
          total_commits_count: 1,
          commits: [{ id: sha, message: title, timestamp: (7.days.ago + n.minutes).iso8601 }],
        )
      when "workflow_run"
        event = "Pipeline Hook"
        data.merge!(
          object_kind: "pipeline",
          object_attributes: {
            id: n * 10,
            ref: "main",
            sha: sha,
            status: state,
            source: pr ? "merge_request_event" : "push",
            url: "#{url}/-/pipelines/#{n}",
          },
          builds: [{ id: n, name: "test", stage: "test", status: state }],
        )
        data[:merge_request] = { iid: n } if pr
      when "pull_request"
        event = "Merge Request Hook"
        data.merge!(
          object_kind: "merge_request",
          object_attributes: {
            iid: n,
            action: pr ? "merge" : "open",
            title: title,
            url: "#{url}/-/merge_requests/#{n}",
            source_project_id: c.id + 10_000,
            target_project_id: c.id,
            last_commit: {
              id: sha,
            },
          },
        )
      when "issues"
        event = "Issue Hook"
        data.merge!(
          object_kind: "issue",
          object_attributes: {
            iid: n,
            action: "open",
            title: title,
            url: "#{url}/-/issues/#{n}",
          },
        )
      when "release"
        event = "Release Hook"
        data.merge!(action: "create", name: "Aurora v#{n}.0", tag: "v#{n}.0")
      end
    end
    [event, JSON.generate(data)]
  end

  def deliver(c, uri, event, body, invalid: false, delivery: SecureRandom.uuid)
    headers = { "Content-Type" => "application/json" }
    if c.forge == "github"
      headers.merge!(
        "X-GitHub-Event" => event,
        "X-GitHub-Delivery" => delivery,
        "X-Hub-Signature-256" =>
          "sha256=#{invalid ? "0" * 64 : OpenSSL::HMAC.hexdigest("SHA256", c.secret, body)}",
      )
    else
      headers.merge!(
        "X-Gitlab-Event" => event,
        "X-Gitlab-Event-UUID" => delivery,
        "X-Gitlab-Token" => invalid ? "invalid-simulation-token" : c.secret,
      )
    end
    request = Net::HTTP::Post.new("/repo-activity/hooks/#{c.public_id}", headers)
    request.body = body
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response =
      Net::HTTP.start(uri.host, uri.port, read_timeout: 30) { |http| http.request(request) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    Discourse.redis.rpush(
      "ra-sim:latency",
      { ms: elapsed * 1000, status: response.code.to_i }.to_json,
    )
    response.code.to_i
  end

  def stats(values)
    sorted = values.sort
    return { count: 0 } if sorted.empty?
    {
      count: sorted.size,
      p50: sorted[(sorted.size - 1) / 2].round(3),
      p95: sorted[((sorted.size - 1) * 0.95).ceil].round(3),
      max: sorted.last.round(3),
    }
  end

  def report
    samples = Discourse.redis.lrange("ra-sim:latency", 0, -1).map { |v| JSON.parse(v) }
    result = {
      webhook_ms: stats(samples.map { |v| v["ms"] }),
      statuses: samples.group_by { |v| v["status"] }.transform_values(&:size),
      jobs_seconds:
        %w[RepoActivityAnnounce RepoActivityPublish].to_h do |name|
          [name, stats(Discourse.redis.lrange("ra-sim:jobs:#{name}", 0, -1).map(&:to_f))]
        end,
      publishes: Discourse.redis.hgetall("ra-sim:publishes"),
      job_errors: Discourse.redis.lrange("ra-sim:errors", 0, -1),
      tables:
        %w[connections refs events channel_reads].to_h do |t|
          [t, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM repo_activity_#{t}")]
        end,
      bot_messages: Chat::Message.where(user_id: DiscourseRepoActivity::Bot.user.id).count,
      users: User.where("username LIKE 'sim_%'").count,
      channels:
        connections
          .includes(:chat_channel)
          .map(&:chat_channel)
          .uniq
          .map { |c| { id: c.id, name: c.name, url: "/chat/c/#{c.slug}/#{c.id}" } },
    }
    puts JSON.pretty_generate(result)
  end
end

sim = RepoActivitySimulation
case options[:mode]
when "seed"
  sim.seed
when "week"
  sim.seed
  list = sim.connections.to_a

  7.times do |day|
    list.each_with_index do |c, index|
      next if %w[archive planning].any? { |name| c.repo_path.include?(name) }
      pushes = index.zero? ? 30 : (index < 5 ? 4 : 1)
      pushes.times do |push|
        n = day * 1000 + push * 3
        event, body = sim.payload(c, "push", n)
        delivery = SecureRandom.uuid
        sim.deliver(c, uri, event, body, delivery: delivery)
        sim.deliver(c, uri, event, body, delivery: delivery) if push.zero?
        sim.deliver(c, uri, event, body, invalid: true) if push.zero?
        (c.forge == "github" ? 3 : 1).times do |workflow|
          event, body = sim.payload(c, "workflow_run", n + workflow)
          # All workflows describe the same commit, while retaining stable workflow IDs.
          parsed = JSON.parse(body)
          if c.forge == "github"
            parsed["workflow_run"]["head_sha"] = Digest::SHA1.hexdigest("#{c.id}:#{n}")
          end
          sim.deliver(c, uri, event, JSON.generate(parsed))
        end
        sleep(2.3) if index.zero?
      end
      %w[pull_request workflow_run issues release].each_with_index do |kind, ki|
        next if kind == "release" && day != 6
        event, body = sim.payload(c, kind, day * 1000 + 500 + ki, pr: kind == "workflow_run")
        sim.deliver(c, uri, event, body)
      end
    end
    puts({ day: day + 1, delivered: Discourse.redis.llen("ra-sim:latency") }.to_json)
  end

  list
    .first(2)
    .each do |c|
      event, body = sim.payload(c, "workflow_run", 90_000, state: "failed")
      sim.deliver(c, uri, event, body)
    end
  puts "Waiting for the real two-minute announcement window"
  sleep 135
  c = list.first
  event, body = sim.payload(c, "workflow_run", 90_000)
  sim.deliver(c, uri, event, body)
  puts "Waiting for scheduled recovery edit and thread reply"
  sleep 135
  sim.report
when "report"
  sim.report
when "metrics-reset"
  Discourse.redis.scan_each(match: "ra-sim:*") { |key| Discourse.redis.del(key) }
  puts "Only simulation measurements reset"
when "edges"
  sim
    .connections
    .first(4)
    .each_with_index do |fixture_connection, index|
      5.times do |number|
        event, body = sim.payload(fixture_connection, "pull_request", 80_000 + number)
        sim.deliver(fixture_connection, uri, event, body)
      end
      event, body = sim.payload(fixture_connection, "pull_request", 80_000, pr: true)
      sim.deliver(fixture_connection, uri, event, body)
      event, body = sim.payload(fixture_connection, "push", 81_000)
      tag = JSON.parse(body)
      tag["ref"] = "refs/tags/v81000.0"
      sim.deliver(
        fixture_connection,
        uri,
        fixture_connection.forge == "github" ? "push" : "Tag Push Hook",
        JSON.generate(tag),
      )
      event, body = sim.payload(fixture_connection, "release", 81_000)
      sim.deliver(fixture_connection, uri, event, body)
      event, body = sim.payload(fixture_connection, "workflow_run", 82_000 + index, state: "failed")
      sim.deliver(fixture_connection, uri, event, body)
    end
  puts "Burst PRs, merges, tags/releases and independent failures delivered"
  sim.report
when "incident"
  ActiveRecord::Base.uncached do
    # Reproduce a flapping incident before its first scheduled announcement.
    target = sim.connections.find_by!(repo_path: "aurora/engineering-3")
    repair = sim.connections.find_by!(repo_path: "aurora/engineering-1")
    [
      [target, 100_002, "failed"],
      [target, 100_005, "success"],
      [target, 100_008, "failed"],
      [repair, 100_008, "failed"],
    ].each do |repo, number, state|
      event, body = sim.payload(repo, "workflow_run", number, state: state)
      raise "Incident delivery failed" unless sim.deliver(repo, uri, event, body) == 200
    end
    puts "Waiting for real scheduler to post the flapping incident"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 200
    loop do
      ref = target.refs.find_by!(ref_name: "main")
      break if ref.failure_message_id.present?
      raise "Announcement timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 1
    end
    raise "Incident marker was lost" unless target.refs.find_by!(ref_name: "main").failing_since
    alert_ids =
      [target, repair].map { |repo| repo.refs.find_by!(ref_name: "main").failure_message_id }
    [target, repair].each do |repo|
      event, body = sim.payload(repo, "workflow_run", 100_011)
      raise "Recovery delivery failed" unless sim.deliver(repo, uri, event, body) == 200
    end
    puts "Waiting for real scheduled alert edits and threaded recovery replies"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 200
    loop do
      replies = Chat::Message.where(in_reply_to_id: alert_ids).count
      break if replies >= alert_ids.size
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "Threaded recovery timed out"
      end
      sleep 1
    end
    unless Chat::Message
             .where(id: alert_ids)
             .all? { |message| message.message.include?("fixed in") }
      raise "Alert was not edited"
    end
    puts "Flapping-incident marker, alert edits and threaded recoveries passed through HTTP and real jobs"
    sim.report
  end
when "reset"
  # Remove only activity owned by this fixture. Categories, users and conversation
  # are reused on re-seed; no unrelated local data or Redis keys are removed.
  fixture_channels = sim.connections.reorder(nil).distinct.pluck(:chat_channel_id)
  bot_id = PluginStore.get(DiscourseRepoActivity::PLUGIN_NAME, "bot_user_id")
  Chat::Message.where(chat_channel_id: fixture_channels, user_id: bot_id).destroy_all if bot_id
  DiscourseRepoActivity::ChannelRead.where(chat_channel_id: fixture_channels).delete_all
  sim.connections.each do |fixture_connection|
    fixture_connection.events.delete_all
    fixture_connection.refs.delete_all
    Discourse.redis.del("repo-activity:announce:#{fixture_connection.id}")
    Discourse.redis.del("repo-activity:publish:#{fixture_connection.chat_channel_id}")
  end
  Discourse.redis.scan_each(match: "ra-sim:*") { |key| Discourse.redis.del(key) }
  puts "Fixture activity and measurements reset; users and conversation retained"
end
