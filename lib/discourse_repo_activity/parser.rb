# frozen_string_literal: true

module DiscourseRepoActivity
  # Converts allowlisted fields only. No descriptions, diffs or complete payloads survive parsing.
  class Parser
    def initialize(connection, payload)
      @connection, @payload = connection, payload
    end

    def parse(event)
      result = @connection.forge == "github" ? github(event) : gitlab(event)
      return unless result
      result[:default_branch] = text(
        @payload.dig(@connection.forge == "github" ? "repository" : "project", "default_branch"),
        200,
      )
      result[:actor] = text(result[:actor], 100)
      result[:ref_name] = text(result[:ref_name], 300)
      result[:sha] = result[:sha].to_s[/\A[0-9a-f]{7,64}\z/i] if result.key?(:sha)
      result[:summary] ||= {}
      result[:summary].transform_values! { |value| value.is_a?(String) ? text(value, 500) : value }
      result[:summary][:url] = safe_url(result[:summary][:url])
      result
    end

    private

    def github(event)
      p = @payload
      actor = p.dig("sender", "login")
      case event
      when "push"
        tag = p["ref"].to_s.start_with?("refs/tags/")
        ref = p["ref"].to_s.sub(%r{\Arefs/(heads|tags)/}, "")
        return if p["deleted"] && tag
        {
          kind: tag ? "tag" : "push",
          actor: p.dig("pusher", "name") || actor,
          ref_name: ref,
          sha: p["after"],
          delete_ref: p["deleted"],
          summary: {
            tag: tag ? ref : nil,
            title: tag ? "Tag #{ref}" : "Push to #{ref}",
            url:
              (
                if tag
                  "#{base}/releases/tag/#{ERB::Util.url_encode(ref)}"
                else
                  p["compare"]
                end
              ),
            commit_count: [p["size"].to_i, Array(p["commits"]).size].max,
            commits: commits(p["commits"]),
            last_commit: text(p.dig("head_commit", "message").to_s.lines.first, 200),
          },
        }
      when "workflow_run"
        run = p["workflow_run"] || {}
        return if run["workflow_id"].blank?
        pr =
          Array(run["pull_requests"]).find do |item|
            item["number"].present? && item.dig("base", "repo", "id") == p.dig("repository", "id")
          end
        foreign =
          run.dig("head_repository", "id").present? &&
            run.dig("head_repository", "id") != p.dig("repository", "id")
        return if !pr && (foreign || %w[pull_request pull_request_target].include?(run["event"]))
        {
          kind: "ci",
          actor: run.dig("head_commit", "author", "username") || run.dig("actor", "login") || actor,
          ref_name: pr ? "pr/#{pr["number"]}" : run["head_branch"],
          ref_kind: pr ? "pr" : "branch",
          pr_number: pr&.dig("number"),
          sha: run["head_sha"],
          ci_state: state(run["conclusion"].presence || run["status"]),
          run_name: text(run["name"].presence || "Workflow", 100),
          run_key: run["workflow_id"].to_s,
          run_id: run["id"].to_i,
          run_attempt: run["run_attempt"].to_i,
          summary: {
            title: "#{run["name"]}: #{run["conclusion"].presence || run["status"]}",
            url: run["html_url"],
          },
        }
      when "pull_request"
        pr = p["pull_request"] || {}
        action = p["action"]
        kind =
          action == "opened" ? "pr_opened" : action == "closed" && pr["merged"] ? "pr_merged" : nil
        return unless kind || action == "closed"
        {
          kind: kind || "pr_closed",
          actor: actor,
          ref_name: "pr/#{pr["number"] || p["number"]}",
          ref_kind: "pr",
          pr_number: pr["number"] || p["number"],
          sha: pr.dig("head", "sha"),
          delete_ref: action == "closed",
          summary: {
            title: pr["title"],
            number: pr["number"] || p["number"],
            url: pr["html_url"],
          },
        }
      when "issues"
        return unless p["action"] == "opened"
        {
          kind: "issue_opened",
          actor: actor,
          summary: {
            title: p.dig("issue", "title"),
            number: p.dig("issue", "number"),
            url: p.dig("issue", "html_url"),
          },
        }
      when "release"
        return unless p["action"] == "published"
        release = p["release"] || {}
        {
          kind: "release",
          actor: actor,
          summary: {
            title: release["name"].presence || release["tag_name"],
            tag: release["tag_name"],
            url: release["html_url"],
          },
        }
      end
    end

    def gitlab(event)
      p = @payload
      attrs = p["object_attributes"] || {}
      actor = p.dig("user", "username") || p["user_username"]
      case event
      when "Push Hook", "Tag Push Hook"
        tag = event == "Tag Push Hook"
        ref = p["ref"].to_s.sub(%r{\Arefs/(heads|tags)/}, "")
        deleted = p["after"].to_s.match?(/\A0+\z/)
        return if tag && deleted
        {
          kind: tag ? "tag" : "push",
          actor: actor,
          ref_name: ref,
          sha: p["after"],
          delete_ref: deleted,
          summary: {
            tag: tag ? ref : nil,
            title: tag ? "Tag #{ref}" : "Push to #{ref}",
            url:
              (
                if tag
                  "#{base}/-/tags/#{ERB::Util.url_encode(ref)}"
                else
                  "#{base}/-/commit/#{p["after"]}"
                end
              ),
            commit_count: [p["total_commits_count"].to_i, Array(p["commits"]).size].max,
            commits: commits(p["commits"]),
            last_commit: text(Array(p["commits"]).last&.dig("message").to_s.lines.first, 200),
          },
        }
      when "Pipeline Hook"
        number =
          p.dig("merge_request", "iid") || attrs["merge_request_iid"] ||
            attrs["ref"].to_s[%r{merge-requests/(\d+)}, 1]
        pr = number.present? || attrs["source"] == "merge_request_event"
        return if pr && number.blank?
        {
          kind: "ci",
          actor: actor,
          ref_name: pr ? "pr/#{number}" : attrs["ref"],
          ref_kind: pr ? "pr" : "branch",
          pr_number: number&.to_i,
          sha: attrs["sha"],
          ci_state: state(attrs["status"]),
          run_name: "Pipeline",
          run_id: attrs["id"].to_i,
          run_attempt: 0,
          summary: {
            title: "Pipeline #{attrs["status"]}",
            url: attrs["url"] || "#{base}/-/pipelines/#{attrs["id"]}",
          },
          jobs:
            Array(p["builds"])
              .select { |b| b["status"] == "failed" }
              .first(30)
              .map { |b| text(b["name"], 100) },
        }
      when "Merge Request Hook"
        action = attrs["action"]
        kind = { "open" => "pr_opened", "merge" => "pr_merged", "close" => "pr_closed" }[action]
        return unless kind
        {
          kind: kind,
          actor: actor,
          ref_name: "pr/#{attrs["iid"]}",
          ref_kind: "pr",
          pr_number: attrs["iid"],
          sha: attrs.dig("last_commit", "id"),
          delete_ref: %w[merge close].include?(action),
          summary: {
            title: attrs["title"],
            number: attrs["iid"],
            url: attrs["url"],
          },
        }
      when "Issue Hook"
        return unless attrs["action"] == "open"
        {
          kind: "issue_opened",
          actor: actor,
          summary: {
            title: attrs["title"],
            number: attrs["iid"],
            url: attrs["url"],
          },
        }
      when "Release Hook"
        return unless p["action"] == "create"
        {
          kind: "release",
          actor: actor,
          summary: {
            title: p["name"].presence || p["tag"],
            tag: p["tag"],
            url: "#{base}/-/releases/#{ERB::Util.url_encode(p["tag"].to_s)}",
          },
        }
      end
    end

    def commits(values)
      Array(values)
        .last(20)
        .filter_map do |commit|
          sha = commit["id"].to_s[/\A[0-9a-f]{7,64}\z/i]
          next unless sha
          {
            sha: sha,
            message: text(commit["message"].to_s.lines.first, 300),
            author: text(commit.dig("author", "username") || commit.dig("author", "name"), 100),
            url:
              safe_url(commit["url"]) ||
                "#{base}/#{@connection.forge == "github" ? "commit" : "-/commit"}/#{sha}",
          }
        end
    end

    def state(value)
      case value
      when "failure", "failed", "timed_out", "action_required", "startup_failure", "stale"
        "failed"
      when "success"
        "success"
      when "neutral", "skipped", "cancelled", "canceled"
        "neutral"
      when "queued", "pending", "created", "waiting_for_resource", "requested", "waiting"
        "pending"
      else
        "running"
      end
    end

    def base
      @connection.repository_url
    end

    def text(value, length)
      value.to_s.gsub(/[[:cntrl:]]/, " ").strip.truncate(length, omission: "")
    end

    def safe_url(value)
      uri = URI.parse(value.to_s)
      # Never turn attacker-controlled webhook links into off-forge or script links.
      if uri.scheme == "https" && uri.userinfo.nil? &&
           uri.host == @connection.host.split(":").first &&
           uri.path.downcase.start_with?("/#{@connection.repo_path.downcase}/")
        uri.to_s
      end
    rescue URI::InvalidURIError
      nil
    end
  end
end
