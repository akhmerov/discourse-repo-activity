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
      return if c.enabled_events.exclude?(kind)
      summary =
        data[:summary].merge(sha: data[:sha], ref: data[:ref_name]).compact
      loud = !%w[push ci].include?(kind)
      if %w[push ci pr_opened].include?(kind) && data[:ref_name].present?
        ref = c.refs.find_or_initialize_by(ref_name: data[:ref_name])
        ref.kind = data[:ref_kind] || "branch"
        ref.pr_number = data[:pr_number]
        if kind == "ci"
          return if stale_ci?(ref, data)
          ref.ci_runs = {} if ref.head_sha != data[:sha]
          ref.head_sha = data[:sha]
          runs = ref.ci_runs
          runs[data[:run_name]] = {
            state: data[:ci_state],
            url: summary[:url],
            id: data[:run_id],
            attempt: data[:run_attempt],
            jobs: data[:jobs]
          }
          ref.ci_runs = runs
          states = runs.values.map { |r| r[:state] || r["state"] }
          ref.ci_state =
            states.include?("failed") ?
              "failed" :
              states.all?("success") ? "success" : "running"
          summary[:jobs] = data[:jobs] if data[:jobs]
          # Keep the pusher from push payloads. A workflow actor may be a rerun operator.
          if ref.kind == "branch" && ref.ref_name == c.default_branch &&
               c.enabled_events.include?("failure")
            if ref.ci_state == "failed"
              ref.failing_since ||= Time.current
              kind = "failure"
              loud = true
            elsif ref.ci_state == "success" && ref.failing_since
              kind = "recovery"
              loud = true
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
      event =
        c.events.create!(
          chat_channel_id: c.chat_channel_id,
          kind: kind,
          actor_login: data[:actor],
          summary: summary,
          loud: loud
        )
      if loud &&
           !c
             .events
             .where(loud: true, chat_message_id: nil)
             .where.not(id: event.id)
             .exists?
        Jobs.enqueue_in(2.minutes, :repo_activity_announce, connection_id: c.id)
      end
    end

    private

    def stale_ci?(ref, data)
      # Push is authoritative for branch heads; an older pipeline must not revert it.
      if ref.head_sha.present? && ref.head_sha != data[:sha] &&
           ref.pushed_by_login.present? && ref.kind == "branch" &&
           @connection
             .events
             .where(kind: "push")
             .where("summary->>'sha' = ?", ref.head_sha)
             .exists? &&
           @connection
             .events
             .where(kind: "push")
             .where("summary->>'sha' = ?", data[:sha])
             .exists?
        return true
      end
      prior = ref.ci_runs[data[:run_name]]
      return false unless prior && ref.head_sha == data[:sha]
      old = [prior["id"].to_i, prior["attempt"].to_i]
      new_run = [data[:run_id], data[:run_attempt]]
      (old <=> new_run) == 1 ||
        (
          old == new_run && %w[success failed].include?(prior["state"]) &&
            %w[running pending].include?(data[:ci_state])
        )
    end
  end
end
