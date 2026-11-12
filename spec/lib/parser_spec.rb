# frozen_string_literal: true

RSpec.describe DiscourseRepoActivity::Parser do
  fab!(:admin)
  fab!(:channel, :chat_channel)
  fab!(:github) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: admin,
      forge: "github",
      host: "github.com",
      repo_path: "acme/sim-tools"
    )
  end
  fab!(:gitlab) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: admin,
      forge: "gitlab",
      host: "gitlab.tudelft.nl",
      repo_path: "group/nested/sim-tools"
    )
  end

  it "maps the supported GitHub fixtures" do
    results = [
      repo_parse(github, "github_push", "push"),
      repo_parse(github, "github_tag", "push"),
      repo_parse(github, "github_workflow_run", "workflow_run"),
      repo_parse(github, "github_pull_request", "pull_request"),
      repo_parse(
        github,
        "github_pull_request",
        "pull_request",
        { "action" => "closed", "pull_request" => { "merged" => true } }
      ),
      repo_parse(github, "github_issues", "issues"),
      repo_parse(github, "github_release", "release")
    ]
    expect(results.map { |result| result[:kind] }).to eq(
      %w[push tag ci pr_opened pr_merged issue_opened release]
    )
    expect(results.first[:summary]).to include(
      last_commit: "Fix solver",
      commit_count: 1
    )
    expect(results.last[:summary][:tag]).to eq("v1.0")
    expect(results.map { |result| result[:default_branch] }.uniq).to eq(
      ["main"]
    )
  end

  it "maps the supported nested-group GitLab fixtures" do
    results = [
      repo_parse(gitlab, "gitlab_push", "Push Hook"),
      repo_parse(gitlab, "gitlab_tag", "Tag Push Hook"),
      repo_parse(gitlab, "gitlab_pipeline", "Pipeline Hook"),
      repo_parse(gitlab, "gitlab_merge_request", "Merge Request Hook"),
      repo_parse(
        gitlab,
        "gitlab_merge_request",
        "Merge Request Hook",
        { "object_attributes" => { "action" => "merge" } }
      ),
      repo_parse(gitlab, "gitlab_issue", "Issue Hook"),
      repo_parse(gitlab, "gitlab_release", "Release Hook")
    ]
    expect(results.map { |result| result[:kind] }).to eq(
      %w[push tag ci pr_opened pr_merged issue_opened release]
    )
    expect(results[2][:jobs]).to eq(["test"])
    expect(results.last[:summary][:url]).to eq(
      "https://gitlab.tudelft.nl/group/nested/sim-tools/-/releases/v1.0"
    )
  end

  it "keeps PR and MR pipelines separate from default branch CI" do
    github_run =
      repo_parse(
        github,
        "github_workflow_run",
        "workflow_run",
        { "workflow_run" => { "pull_requests" => [{ "number" => 8 }] } }
      )
    gitlab_run =
      repo_parse(
        gitlab,
        "gitlab_pipeline",
        "Pipeline Hook",
        { "merge_request" => { "iid" => 8 } }
      )
    expect([github_run[:ref_kind], gitlab_run[:ref_kind]]).to eq(%w[pr pr])
    expect([github_run[:ref_name], gitlab_run[:ref_name]]).to eq(%w[pr/8 pr/8])
  end

  it "discards untrusted URLs and all bodies" do
    body = "Sensitive issue body"
    parsed =
      repo_parse(
        github,
        "github_issues",
        "issues",
        { "issue" => { "html_url" => "javascript:alert(1)", "body" => body } }
      )
    expect(parsed[:summary][:url]).to be_nil
    expect(parsed.to_json).not_to include(body)
  end

  it "marks closed PR refs for deletion even without a merge" do
    result =
      repo_parse(
        github,
        "github_pull_request",
        "pull_request",
        { "action" => "closed" }
      )
    expect(result).to include(
      kind: "pr_closed",
      delete_ref: true,
      ref_name: "pr/8"
    )
  end
  it "skips unidentified fork and PR workflows even when their branch is main" do
    [
      { "event" => "pull_request" },
      { "event" => "pull_request_target" },
      { "head_repository" => { "id" => 99 } }
    ].each do |run|
      expect(
        repo_parse(
          github,
          "github_workflow_run",
          "workflow_run",
          "workflow_run" => run
        )
      ).to be_nil
      parsed =
        repo_parse(
          github,
          "github_workflow_run",
          "workflow_run",
          "workflow_run" => run.merge("pull_requests" => [{ "number" => 8 }])
        )
      expect(parsed).to include(ref_kind: "pr", ref_name: "pr/8")
    end
  end

  it "preserves uppercase GitHub paths without accepting off-repository links" do
    parsed =
      repo_parse(
        github,
        "github_issues",
        "issues",
        "issue" => {
          "html_url" => "https://github.com/Acme/Sim-Tools/issues/1"
        }
      )
    expect(parsed[:summary][:url]).to eq(
      "https://github.com/Acme/Sim-Tools/issues/1"
    )
    %w[
      https://github.com/acme/sim-tools-other/issues/1
      http://github.com/Acme/Sim-Tools/issues/1
      https://evil.example/Acme/Sim-Tools/issues/1
    ].each do |url|
      expect(
        repo_parse(
          github,
          "github_issues",
          "issues",
          "issue" => {
            "html_url" => url
          }
        )[
          :summary
        ][
          :url
        ]
      ).to be_nil
    end
  end

  it "skips MR pipelines without an MR number instead of creating pipeline refs" do
    expect(
      repo_parse(
        gitlab,
        "gitlab_pipeline",
        "Pipeline Hook",
        "object_attributes" => {
          "source" => "merge_request_event"
        }
      )
    ).to be_nil
  end
  it "skips GitHub runs without workflow identity" do
    expect(
      repo_parse(
        github,
        "github_workflow_run",
        "workflow_run",
        "workflow_run" => {
          "workflow_id" => nil
        }
      )
    ).to be_nil
  end
end
