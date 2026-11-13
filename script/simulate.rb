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
    p.on(
      "--mode MODE",
      %w[seed week report reset metrics-reset edges incident showcase polish replay],
    ) { |v| options[:mode] = v }
    p.on("--url URL") { |v| options[:url] = v }
  end
  .parse!(ARGV)
uri = URI(options[:url])
unless %w[127.0.0.1 localhost].include?(uri.host) && uri.scheme == "http"
  abort "Only local HTTP destinations are allowed"
end

module RepoActivitySimulation
  extend self
  def presentation_time(index, count, quiet:, lag:)
    days =
      (0..14).map { |offset| Date.current - offset }.reject { |day| day.saturday? || day.sunday? }
    days = days.drop(2) if quiet
    days = days.first(6).reverse
    available =
      (
        if days.last == Date.current
          ((Time.current - days.last.in_time_zone.change(hour: 9)) / 60 - lag).floor.clamp(0, 439)
        else
          439 - lag
        end
      )
    slot = index * ((days.length - 1) * 440 + available) / [count - 1, 1].max
    days[slot / 440].in_time_zone.change(hour: 9) + (slot % 440).minutes
  end

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

  REPO_NAMES = %w[
    kwant-ext
    mesh-tools
    eigenflow
    lab-notebooks
    transport-bench
    spectra-fit
    bootstrap-tools
    phase-map
    cryo-control
    pulse-sequencer
    aurora-releases
    cluster-jobs
    lab-handbook
    thesis-scripts
    old-benchmarks
  ].freeze
  REPO_WORK = {
    "kwant-ext" => [
      "Cache evanescent lead modes",
      "Check spinful hopping conjugation",
      "Compare sparse LU conductance",
    ],
    "mesh-tools" => [
      "Repair boundary-cell orientation",
      "Keep physical tags on refinement",
      "Validate tetrahedron volumes",
    ],
    "eigenflow" => [
      "Track eigenvectors across crossings",
      "Stabilize degenerate subspaces",
      "Export spectral-flow branches",
    ],
    "lab-notebooks" => [
      "Record environment hashes",
      "Rerun the junction tutorial",
      "Fix notebook figure captions",
    ],
    "transport-bench" => [
      "Measure solver peak memory",
      "Warm up the GPU benchmark",
      "Store BLAS thread counts",
    ],
    "spectra-fit" => [
      "Fit asymmetric spectral peaks",
      "Weight residuals by shot noise",
      "Plot posterior predictive bands",
    ],
    "bootstrap-tools" => [
      "Resample experimental batches",
      "Handle three-sample intervals",
      "Seed independent bootstrap workers",
    ],
    "phase-map" => [
      "Refine the critical-field grid",
      "Mask unconverged phase points",
      "Compare finite-size gap scaling",
    ],
    "cryo-control" => [
      "Debounce the temperature interlock",
      "Persist sensor calibration units",
      "Retry interrupted ramp commands",
    ],
    "pulse-sequencer" => [
      "Align trigger and ADC clocks",
      "Validate microwave duty cycles",
      "Preview shaped pulse envelopes",
    ],
    "aurora-releases" => [
      "Verify signed environment exports",
      "Assemble the lab software bundle",
      "Check upgrade migration notes",
    ],
    "cluster-jobs" => [
      "Retry preempted Slurm arrays",
      "Limit concurrent GPU workers",
      "Record scheduler accounting data",
    ],
    "lab-handbook" => [
      "Clarify the cryostat booking rules",
      "Add an onboarding checklist",
      "Update the data-retention guide",
    ],
    "thesis-scripts" => [
      "Restore archived figure sources",
      "Document the frozen Python stack",
      "Verify deposited data checksums",
    ],
    "old-benchmarks" => [
      "Archive obsolete solver baselines",
      "Record historical compiler flags",
      "Index legacy timing datasets",
    ],
  }.freeze
  AUTHORS = %w[
    sim_theo_linden
    sim_nora_finch
    sim_sana_brook
    sim_eli_rowan
    jchen
    m-rojas
    external-kai
  ].freeze

  COMMIT_MESSAGES = [
    "Use sparse LU for lead self-energies",
    "Check current conservation at zero bias",
    "Cache transverse modes between energy points",
    "Fix conjugation in spinful hopping",
    "Add a regression for degenerate band crossings",
    "Normalize wave functions before projection",
    "Reduce peak memory in the KPM kernel",
    "Vectorize the bootstrap resampling loop",
    "Document the lattice convention used by the notebooks",
    "Keep units on the acquisition time axis",
    "Handle empty slices in the symmetry reduction",
    "Compare the finite-size gap with the continuum limit",
    "Export reproducible metadata with the phase diagram",
    "Stabilize the fit near the critical field",
    "Add uncertainty bounds to the calibration curve",
    "Check Hermiticity before diagonalization",
  ].freeze
  PR_TITLES = [
    "Add GPU sparse solver support",
    "Compare Landauer conductance with Kubo response",
    "Make the disorder sweep reproducible",
    "Track units through the calibration pipeline",
    "Support non-orthogonal lead cells",
    "Add a tutorial on spin-orbit transport",
    "Parallelize independent energy points",
    "Publish the benchmark notebook",
  ].freeze
  ISSUE_TITLES = [
    "Conductance drifts at the band edge",
    "Bootstrap intervals collapse for three samples",
    "Acquisition timestamps wrap after midnight",
    "Notebook figures use the old lattice convention",
    "Large supercells exceed the worker memory limit",
  ].freeze

  DISCUSSIONS = {
    "Engineering" => [
      "Morning! I have a first pass at the lead-mode solver ready for review.",
      "Thanks. I will compare the sparse factorization with last week’s baseline after lunch.",
      "The transport regression still needs a second pair of eyes before we share it.",
      "I checked the lead-mode solver; the reference values agree within the error bars.",
      "Could you add the environment and random seed to the sparse factorization notes?",
      "Done. Let’s discuss the transport regression at the next group meeting.",
    ],
    "Analysis" => [
      "Morning! I have a first pass at the bootstrap notebook ready for review.",
      "Thanks. I will compare the finite-size fit with last week’s baseline after lunch.",
      "The uncertainty estimate still needs a second pair of eyes before we share it.",
      "I checked the bootstrap notebook; the reference values agree within the error bars.",
      "Could you add the environment and random seed to the finite-size fit notes?",
      "Done. Let’s discuss the uncertainty estimate at the next group meeting.",
    ],
    "Instruments" => [
      "Morning! I have a first pass at the cryostat calibration ready for review.",
      "Thanks. I will compare the pulse sequence with last week’s baseline after lunch.",
      "The acquisition timestamp still needs a second pair of eyes before we share it.",
      "I checked the cryostat calibration; the reference values agree within the error bars.",
      "Could you add the environment and random seed to the pulse sequence notes?",
      "Done. Let’s discuss the acquisition timestamp at the next group meeting.",
    ],
    "Releases" => [
      "Morning! I have a first pass at the release candidate ready for review.",
      "Thanks. I will compare the reproducible environment with last week’s baseline after lunch.",
      "The migration note still needs a second pair of eyes before we share it.",
      "I checked the release candidate; the reference values agree within the error bars.",
      "Could you add the environment and random seed to the reproducible environment notes?",
      "Done. Let’s discuss the migration note at the next group meeting.",
    ],
    "Operations" => [
      "Morning! I have a first pass at the cluster queue ready for review.",
      "Thanks. I will compare the worker memory budget with last week’s baseline after lunch.",
      "The overnight sweep still needs a second pair of eyes before we share it.",
      "I checked the cluster queue; the reference values agree within the error bars.",
      "Could you add the environment and random seed to the worker memory budget notes?",
      "Done. Let’s discuss the overnight sweep at the next group meeting.",
    ],
    "Documentation" => [
      "Morning! I have a first pass at the lead-convention tutorial ready for review.",
      "Thanks. I will compare the notebook gallery with last week’s baseline after lunch.",
      "The installation guide still needs a second pair of eyes before we share it.",
      "I checked the lead-convention tutorial; the reference values agree within the error bars.",
      "Could you add the environment and random seed to the notebook gallery notes?",
      "Done. Let’s discuss the installation guide at the next group meeting.",
    ],
    "Archive" => [
      "Morning! I have a first pass at the old benchmark dataset ready for review.",
      "Thanks. I will compare the thesis script with last week’s baseline after lunch.",
      "The archived environment still needs a second pair of eyes before we share it.",
      "I checked the old benchmark dataset; the reference values agree within the error bars.",
      "Could you add the environment and random seed to the thesis script notes?",
      "Done. Let’s discuss the archived environment at the next group meeting.",
    ],
    "Planning" => [
      "Morning! I have a first pass at the next transport sweep ready for review.",
      "Thanks. I will compare the instrument allocation with last week’s baseline after lunch.",
      "The group-meeting agenda still needs a second pair of eyes before we share it.",
      "I checked the next transport sweep; the reference values agree within the error bars.",
      "Could you add the environment and random seed to the instrument allocation notes?",
      "Done. Let’s discuss the group-meeting agenda at the next group meeting.",
    ],
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
        connection =
          DiscourseRepoActivity::Connection.find_or_create_by!(
            chat_channel: channel,
            repo_path: path,
          ) do |c|
            c.created_by = owner
            c.forge = forge
            c.host = forge == "github" ? "github.com" : "git.aurora.example"
            c.default_branch = "main"
          end
        connection.update!(display_name: REPO_NAMES[CHANNELS.values.first(ci).sum + ri])
      end
      if channel.chat_messages.where(user_id: people.map(&:id)).empty?
        DISCUSSIONS
          .fetch(name)
          .each_with_index do |text, i|
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
    actor = AUTHORS[(n + c.repo_path.bytes.sum) % AUTHORS.length]
    url = c.repository_url
    salt = c.repo_path.bytes.sum
    title =
      case kind
      when "pull_request"
        REPO_WORK.fetch(c.display_name)[n % 3]
      when "issues"
        "#{REPO_WORK.fetch(c.display_name)[n % 3]}: unexpected edge case"
      when "release"
        "#{c.display_name} #{1 + salt % 3}.#{salt % 9}.#{n % 7} — #{REPO_WORK.fetch(c.display_name).first.downcase}"
      else
        REPO_WORK.fetch(c.display_name)[(n + salt) % 3]
      end
    branch = n % 9 == 0 ? "main" : %w[solver-cache error-estimates band-crossings][(n / 3) % 3]
    commit_list =
      (0..(n % 3)).map do |i|
        {
          id: (commit_sha = i.zero? ? sha : Digest::SHA1.hexdigest("#{c.id}:#{n}:#{i}")),
          message: i.zero? ? title : REPO_WORK.fetch(c.display_name)[(n + i + salt) % 3],
          author: {
            username: actor,
            name: actor.delete_prefix("sim_").tr("_", " ").titleize,
          },
          url: "#{url}/#{c.forge == "github" ? "commit" : "-/commit"}/#{commit_sha}",
          timestamp: (7.days.ago + n.minutes).iso8601,
        }
      end
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
          ref: "refs/heads/#{branch}",
          before: Digest::SHA1.hexdigest("before#{n}"),
          after: sha,
          forced: n % 30 == 0,
          deleted: false,
          compare: "#{url}/compare/base...#{sha}",
          pusher: {
            name: actor,
          },
          commits: commit_list,
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
            name: title,
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
          ref: "refs/heads/#{branch}",
          before: Digest::SHA1.hexdigest("before#{n}"),
          after: sha,
          total_commits_count: commit_list.length,
          commits: commit_list,
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
        data.merge!(action: "create", name: title, tag: "v#{n}.0")
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
      self_deleted_alerts:
        Chat::Message.only_deleted.where(user_id: DiscourseRepoActivity::Bot.user.id).count,
      channel_counts:
        connections
          .includes(:chat_channel)
          .map(&:chat_channel)
          .uniq
          .map do |channel|
            {
              channel: channel.name,
              events: DiscourseRepoActivity::Event.where(chat_channel_id: channel.id).count,
              bot_messages:
                channel.chat_messages.where(user_id: DiscourseRepoActivity::Bot.user.id).count,
              deleted_alerts:
                Chat::Message
                  .only_deleted
                  .where(chat_channel_id: channel.id, user_id: DiscourseRepoActivity::Bot.user.id)
                  .count,
            }
          end,
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
        next if kind == "pull_request" && index > 0 && day.odd?
        next if kind == "issues" && day != index % 7
        event, body = sim.payload(c, kind, day * 1000 + 500 + ki, pr: kind == "workflow_run")
        sim.deliver(c, uri, event, body)
      end
    end
    channel = list[day % 3].chat_channel
    text =
      [
        "The sparse solver is ready for another comparison with the dense baseline.",
        "I checked the band-edge regression; the remaining difference is within tolerance.",
        "Can we keep the acquisition protocol in the release notes?",
        "The latest calibration is on the shared drive. Please use the new uncertainty column.",
        "I will review the transport notebook after the group meeting.",
        "The cluster run finished overnight; the memory profile looks much better.",
        "Thanks for the reviews. I am tagging this week's reproducible dataset.",
      ][
        day
      ]
    unless channel.chat_messages.where(message: text).exists?
      Chat::CreateMessage.call(
        guardian: sim.users(40)[day].guardian,
        params: {
          chat_channel_id: channel.id,
          message: text,
        },
      )
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
  puts "Waiting for scheduled recovery and alert deletion"
  sleep 135
  sim.report
when "showcase"
  # A compact final browse state, also exercising consecutive push grouping.
  generation = Discourse.redis.get("ra-sim:showcase-generation") || SecureRandom.uuid
  Discourse.redis.set("ra-sim:showcase-generation", generation)
  sim
    .connections
    .where.not(repo_path: %w[aurora/engineering-2 aurora/planning-1])
    .each do |repo|
      2.times do |push|
        number = 110_000 + push * 8
        event, body = sim.payload(repo, "push", number)
        data = JSON.parse(body)
        data["ref"] = "refs/heads/main"
        sha = data["after"]
        data["commits"] = 3.times.map do |index|
          commit_sha = index.zero? ? sha : Digest::SHA1.hexdigest("#{repo.id}:#{number}:#{index}")
          {
            id: commit_sha,
            message: sim::REPO_WORK.fetch(repo.display_name)[(push + index) % 3],
            author: {
              username: "sim_mira_vale",
              name: "Mira Vale",
            },
            url:
              "#{repo.repository_url}/#{repo.forge == "github" ? "commit" : "-/commit"}/#{commit_sha}",
          }
        end
        data["total_commits_count"] = 3
        data["size"] = 3
        sim.deliver(
          repo,
          uri,
          event,
          JSON.generate(data),
          delivery: Digest::SHA256.hexdigest("#{generation}:#{repo.id}:#{number}"),
        )
        ci_event, ci_body = sim.payload(repo, "workflow_run", number)
        sim.deliver(
          repo,
          uri,
          ci_event,
          ci_body,
          delivery: Digest::SHA256.hexdigest("#{generation}:#{repo.id}:#{number}:ci"),
        )
      end
    end
  puts "Consecutive commit groups delivered; open mesh-tools failure preserved"
  sim.report
when "polish"
  # Presentation only: replace compressed-counter titles/numbers with plausible
  # research work. Retain event order, CI state and message IDs.
  sim.connections.each do |repo|
    recovered = {}
    repo
      .events
      .where(kind: %w[failure recovery])
      .order(:id)
      .each do |fixture_event|
        ref = fixture_event.summary["ref"]
        recovered[ref] = false if fixture_event.kind == "failure"
        if fixture_event.kind == "recovery"
          # Normalize green receipts ingested before the recovery deduplication fix.
          fixture_event.update!(kind: "ci", loud: false) if recovered[ref]
          recovered[ref] = true
        end
      end
    counters = Hash.new(0)
    repo
      .events
      .where(kind: %w[pr_opened pr_merged issue_opened release tag])
      .order(:id)
      .each do |fixture_event|
        index = counters[fixture_event.kind]
        counters[fixture_event.kind] += 1
        summary = fixture_event.summary.dup
        case fixture_event.kind
        when "pr_opened", "pr_merged", "issue_opened"
          issue = fixture_event.kind == "issue_opened"
          titles = sim::REPO_WORK.fetch(repo.display_name)
          summary[
            "title"
          ] = "#{titles[index % titles.length]}#{issue ? ": edge-case regression" : ""}"
          summary["number"] = repo.repo_path.bytes.sum % 197 + (issue ? 11 : 53) + index
          path = issue ? "issues" : repo.forge == "github" ? "pull" : "-/merge_requests"
          path = "-/issues" if issue && repo.forge == "gitlab"
          summary["url"] = "#{repo.repository_url}/#{path}/#{summary["number"]}"
        when "release", "tag"
          version = "#{1 + repo.id % 3}.#{repo.id % 9}.#{index}"
          summary["tag"] = "v#{version}"
          summary[
            "title"
          ] = "#{repo.display_name} #{version} — #{sim::REPO_WORK.fetch(repo.display_name).first.downcase}"
          summary[
            "url"
          ] = "#{repo.repository_url}/#{repo.forge == "github" ? "releases/tag" : "-/releases"}/v#{version}"
        end
        fixture_event.update!(
          summary: summary,
          actor_login: sim::AUTHORS[(repo.id + index) % sim::AUTHORS.length],
        )
      end
    commit_sequence = 0
    repo
      .events
      .where(kind: "push")
      .order(:id)
      .each_with_index do |push_event, index|
        summary = push_event.summary.deep_dup
        Array(summary["commits"]).each_with_index do |commit, offset|
          sequence = commit_sequence
          commit_sequence += 1
          workloads = [
            "small fixtures",
            "archived measurements",
            "single-worker runs",
            "parallel jobs",
            "empty input",
            "full-resolution data",
            "repeated trials",
            "near-zero values",
            "large batches",
            "nonuniform samples",
          ]
          checks = [
            "after cancellation",
            "on a clean install",
            "with cached results",
            "under memory pressure",
            "after a restart",
            "with missing metadata",
            "at double precision",
            "with deterministic seeds",
            "after serialization",
            "at the convergence threshold",
            "with shuffled inputs",
            "on the reference dataset",
            "after changing the tolerance",
            "with a reduced time step",
            "on a resumed job",
            "without optional accelerators",
            "with a different partition",
            "using the calibration snapshot",
            "after upgrading dependencies",
            "on the regression workload",
          ]
          base = sim::REPO_WORK.fetch(repo.display_name)[sequence % 3]
          commit[
            "message"
          ] = "#{base} for #{workloads[(sequence / 3) % workloads.length]} #{checks[(sequence / 30) % checks.length]}"
          commit["author"] = sim::AUTHORS[(repo.id + index + offset) % sim::AUTHORS.length]
        end
        push_event.update!(
          summary: summary,
          actor_login: sim::AUTHORS[(repo.id + index) % sim::AUTHORS.length],
        )
      end
    # Preserve receipt order while spreading activity over real working days.
    ordered = repo.events.order(:id).to_a
    ordered.each_with_index do |fixture_event, index|
      time =
        sim.presentation_time(
          index,
          ordered.length,
          quiet: repo.chat_channel.name == "Planning",
          lag: 5 + (repo.id % 4) * 23,
        )
      fixture_event.update_columns(created_at: time)
    end
    repo.update_columns(last_delivery_at: ordered.last&.reload&.created_at)
    repo.refs.each do |ref|
      time = repo.events.where("summary->>'ref' = ?", ref.ref_name).maximum(:created_at)
      ref.update_columns(updated_at: time) if time
    end
    repo
      .events
      .where.not(chat_message_id: nil)
      .group_by(&:chat_message_id)
      .each do |id, events|
        next if events.any? { |fixture_event| %w[failure recovery].include?(fixture_event.kind) }
        message = Chat::Message.find_by(id: id, user_id: DiscourseRepoActivity::Bot.user.id)
        next unless message
        raw =
          DiscourseRepoActivity::Announcer.new(repo).send(:render_events, events, mention: false)
        result =
          Chat::UpdateMessage.call(
            guardian: DiscourseRepoActivity::BotGuardian.new(repo),
            params: {
              channel_id: repo.chat_channel_id,
              message_id: id,
              message: raw,
            },
          )
        raise "Fixture message update failed" if result.failure?
        # This materializes fixture text, rather than simulating a user edit.
        message.revisions.delete_all
      end
  end
  sim
    .connections
    .map(&:chat_channel)
    .uniq
    .each do |channel|
      messages = channel.chat_messages.order(:id).to_a
      messages.each_with_index do |message, index|
        time =
          sim.presentation_time(
            index,
            messages.length,
            quiet: channel.name == "Planning",
            lag: 4 + channel.id % 7,
          )
        message.update_columns(created_at: time, updated_at: time)
      end
      latest = channel.chat_messages.where(deleted_at: nil, thread_id: nil).order(:id).last
      channel.update_columns(last_message_id: latest.id) if latest
    end
  people = sim.users(40)
  sim
    .connections
    .map(&:chat_channel)
    .uniq
    .each do |channel|
      channel
        .chat_messages
        .where(user_id: people.map(&:id))
        .order(:id)
        .limit(6)
        .each_with_index do |message, index|
          result =
            Chat::UpdateMessage.call(
              guardian: people.first.guardian,
              params: {
                channel_id: channel.id,
                message_id: message.id,
                message: sim::DISCUSSIONS.fetch(channel.name)[index],
              },
            )
          raise "Fixture conversation update failed" if result.failure?
          message.revisions.delete_all
        end
    end
  analysis = sim.connections.map(&:chat_channel).find { |channel| channel.name == "Analysis" }
  [
    "The new spectra fit is ready. I excluded the first 20 ms after each field step.",
    "Is that settling cut shared by both cooldowns? The second run had a slower thermometer.",
    "Good catch. I used the same cut; I will estimate it separately from the raw trace.",
    "I pushed a residual plot to spectra-fit. The shoulder is still there with a wider cut.",
    "Could that shoulder be the reference sample? It appears at nearly the same field.",
    "The reference peak moves with temperature. This one stays put within the resolution.",
    "Let’s keep both models in the notebook until we have the calibration run.",
    "I can take the calibration tomorrow morning before the ramp experiment.",
    "For bootstrap-tools: please resample whole sweeps, not individual field points.",
    "Agreed, neighboring points share the same drift. I added a batch-level example.",
    "The wider intervals now cover the held-out sweep, which is reassuring.",
    "We should also show the three-sample case; the normal approximation looks misleading.",
    "I left a review on the interval implementation. Only one naming question remains.",
    "Addressed. The random seeds are recorded with the exported confidence bands.",
    "The phase-map refinement finished overnight. Two points near 0.8 T did not converge.",
    "Please mask those before interpolation; otherwise the color scale invents a boundary.",
    "Masked, with the convergence tolerance in the figure caption.",
    "Can someone compare the small-system points against exact diagonalization?",
    "I checked L=12 and L=16. The finite-size drift has the expected sign.",
    "Thanks. I’ll put that check next to the scaling plot for Friday’s discussion.",
    "The calibration slot is confirmed for 09:30. Nora, can you bring the reference sample?",
    "Yes, it is labeled in the dry cabinet. I will also bring the previous cooldown log.",
    "I updated the analysis checklist with the settling-time and batch-resampling decisions.",
    "Great, we can pick this up after the calibration. No need to merge the alternative model yet.",
  ].each_with_index do |text, index|
    next if analysis.chat_messages.exists?(message: text)
    result =
      Chat::CreateMessage.call(
        guardian: people[index % 8].guardian,
        params: {
          chat_channel_id: analysis.id,
          message: text,
        },
      )
    raise "Fixture discussion failed" if result.failure?
  end
  puts "Fixture titles refreshed through native Chat updates; receipt order and CI unchanged"
  sim.report
when "replay"
  %w[reset seed week edges incident showcase polish].each do |mode|
    system(
      RbConfig.ruby,
      Rails.root.join("bin/rails").to_s,
      "runner",
      __FILE__,
      "--mode",
      mode,
      exception: true,
    )
  end
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
    human = sim.users(40)[1]
    Chat::CreateMessage.call(
      guardian: human.guardian,
      params: {
        chat_channel_id: target.chat_channel_id,
        in_reply_to_id: alert_ids.first,
        message: "I reproduced the unstable lead mode. Keeping the investigation here.",
      },
      options: {
        force_thread: true,
      },
    )
    [target, repair].each do |repo|
      event, body = sim.payload(repo, "workflow_run", 100_011)
      raise "Recovery delivery failed" unless sim.deliver(repo, uri, event, body) == 200
    end
    puts "Waiting for real scheduled alert edits and threaded recovery replies"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 200
    loop do
      replies = Chat::Message.where(in_reply_to_id: alert_ids).count
      break if replies >= 2 && Chat::Message.with_deleted.find(alert_ids.last).trashed?
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "Threaded recovery timed out"
      end
      sleep 1
    end
    unless Chat::Message
             .where(id: alert_ids.first)
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
  if bot_id
    Chat::Message.with_deleted.where(chat_channel_id: fixture_channels, user_id: bot_id).destroy_all
  end
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
