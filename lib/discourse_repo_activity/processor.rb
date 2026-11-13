# frozen_string_literal: true

module DiscourseRepoActivity
  class Processor
    def initialize(connection)
      @connection = connection
    end

    # Caller holds the connection and channel locks in a transaction.
    def process(data)
      c = @connection
      c.default_branch = data[:default_branch] if data[:default_branch].present?
      kind = data[:kind]
      if data[:delete_ref]
        c.refs.where(ref_name: data[:ref_name]).delete_all
        return if kind == "pr_closed" || kind == "push"
      end
      return if !%w[push ci pr_opened].include?(kind) && c.enabled_events.exclude?(kind)
      summary = data[:summary].merge(sha: data[:sha], ref: data[:ref_name]).compact
      loud = !%w[push ci].include?(kind)
      if %w[push ci pr_opened].include?(kind) && data[:ref_name].present?
        ref = c.refs.find_or_initialize_by(ref_name: data[:ref_name])
        ref.kind = data[:ref_kind] || "branch"
        ref.pr_number = data[:pr_number]
        if kind == "ci"
          return if stale_ci?(ref, data)
          previous_state, previous_sha = ref.ci_state, ref.head_sha
          ref.ci_runs = {} if ref.head_sha != data[:sha]
          ref.head_sha = data[:sha]
          runs = ref.ci_runs
          runs[run_key(data)] = {
            name: data[:run_name],
            state: data[:ci_state],
            url: summary[:url],
            id: data[:run_id],
            attempt: data[:run_attempt],
            jobs: data[:jobs],
          }
          ref.ci_runs = runs
          states = runs.values.map { |r| r[:state] || r["state"] }
          ref.ci_state =
            states.include?("failed") ?
              "failed" :
              if states.all?("neutral")
                "neutral"
              elsif states.all? { |state| %w[success neutral].include?(state) }
                "success"
              else
                "running"
              end
          summary[:jobs] = data[:jobs] if data[:jobs]
          c
            .events
            .where(kind: "push")
            .where("summary->>'sha' = ?", data[:sha])
            .each do |push|
              push.update!(
                summary:
                  push.summary.merge(
                    "ci_state" => ref.ci_state,
                    "ci_runs" => ref.ci_runs.first(10).to_h,
                  ),
              )
            end
          # Keep the pusher from push payloads. A workflow actor may be a rerun operator.
          if ref.kind == "branch" && ref.ref_name == c.default_branch
            if ref.ci_state == "failed"
              if ref.failing_since.nil? || recovery_recorded?(c, ref)
                ref.failing_since = Time.current
              end
              if c.enabled_events.include?("failure") &&
                   !(previous_state == "failed" && previous_sha == data[:sha])
                kind = "failure"
                loud = true
              end
            elsif ref.ci_state == "success" && ref.failing_since
              if c.enabled_events.include?("recovery") || ref.failure_message_id.present?
                unless recovery_recorded?(c, ref)
                  kind = "recovery"
                  loud = true
                end
              else
                ref.failing_since = nil
                ref.failure_message_id = nil
              end
            end
          end
        elsif ref.head_sha != data[:sha]
          ref.head_sha = data[:sha]
          ref.ci_state = "none"
          ref.ci_runs = {}
        end
        ref.pushed_by_login = data[:actor] if kind == "push"
        ref.save!
      end
      # Disabling recovery replies must never strand a posted red alert.
      cleanup = kind == "recovery" && ref&.failure_message_id.present?
      return if c.enabled_events.exclude?(kind) && !cleanup
      c.events.create!(
        chat_channel_id: c.chat_channel_id,
        kind: kind,
        actor_login: data[:actor],
        summary: summary,
        loud: loud,
      )
      if loud &&
           Discourse.redis.set("repo-activity:announce:#{c.id}", "1", nx: true, ex: 3.minutes.to_i)
        Jobs.enqueue_in(2.minutes, :repo_activity_announce, connection_id: c.id)
      end
    end

    private

    def recovery_recorded?(connection, ref)
      connection
        .events
        .where(kind: "recovery")
        .where("summary->>'ref' = ?", ref.ref_name)
        .where("created_at >= ?", ref.failing_since)
        .exists?
    end

    def run_key(data)
      data[:run_key].presence || data[:run_name]
    end

    def stale_ci?(ref, data)
      # Push is authoritative for branch heads; an older pipeline must not revert it.
      if ref.head_sha.present? && ref.head_sha != data[:sha] && ref.pushed_by_login.present? &&
           ref.kind == "branch" &&
           @connection
             .events
             .where(kind: "push")
             .where("summary->>'sha' = ?", ref.head_sha)
             .exists? &&
           @connection.events.where(kind: "push").where("summary->>'sha' = ?", data[:sha]).exists?
        return true
      end
      prior = ref.ci_runs[run_key(data)]
      return false unless prior && ref.head_sha == data[:sha]
      old = [prior["id"].to_i, prior["attempt"].to_i]
      new_run = [data[:run_id], data[:run_attempt]]
      (old <=> new_run) == 1 ||
        (
          old == new_run && %w[success failed neutral].include?(prior["state"]) &&
            %w[running pending].include?(data[:ci_state])
        )
    end
  end
end
