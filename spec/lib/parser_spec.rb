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
end
