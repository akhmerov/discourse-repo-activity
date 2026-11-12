# frozen_string_literal: true

RSpec.describe DiscourseRepoActivity::Announcer do
  fab!(:admin)
  fab!(:alice) { Fabricate(:user, username: "Alice") }
  fab!(:channel, :chat_channel)
  fab!(:bot) { DiscourseRepoActivity::Bot.ensure! }
  fab!(:connection) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: admin,
      forge: "github",
      host: "github.com",
      repo_path: "acme/sim-tools",
      default_branch: "main"
    )
  end

  before do
    SiteSetting.chat_enabled = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    SiteSetting.repo_activity_enabled = true
    channel.add(alice)
  end

  def workflow(name: "Tests", status: "failure", sha: "a" * 40, **extra)
    repo_process(
      connection,
      repo_parse(
        connection,
        "github_workflow_run",
        "workflow_run",
        {
          "workflow_run" => {
            "name" => name,
            "conclusion" => status,
            "head_sha" => sha
          }.merge(extra.transform_keys(&:to_s))
        }
      )
    )
  end

  def announce
    DiscourseRepoActivity::Announcer.new(connection).announce
  end

  it "combines seen workflows and ignores late running updates" do
    workflow(name: "Lint", status: "success")
    workflow
    expect(connection.refs.first.ci_state).to eq("failed")
    workflow(name: "Tests", status: "success", run_attempt: 2)
    expect(connection.refs.first.ci_state).to eq("success")
    workflow(name: "Tests", status: nil, status_override: "in_progress")
    expect(connection.refs.first.ci_state).to eq("success")
    workflow(name: "Build", status: nil, id: 113)
    expect(connection.refs.first.ci_state).to eq("running")
  end

  it "announces, edits further failures and threads recovery" do
    repo_process(connection, repo_parse(connection, "github_push", "push"))
    workflow
    announce
    message = Chat::Message.where(chat_channel: channel, user: bot).sole
    expect(message.message).to include("@Alice", "CI failing")
    repo_process(
      connection,
      repo_parse(connection, "github_push", "push", { "after" => "b" * 40 })
    )
    workflow(sha: "b" * 40, id: 114)
    announce
    expect(Chat::Message.where(chat_channel: channel, user: bot).count).to eq(1)
    expect(message.reload.message).to include("bbbbbbbb")
    workflow(sha: "b" * 40, status: "success", id: 114, run_attempt: 2)
    announce
    expect(message.reload.message).to include("fixed in bbbbbbbb")
    reply =
      Chat::Message.where(chat_channel: channel, user: bot).order(:id).last
    expect(reply.in_reply_to_id).to eq(message.id)
    expect(reply.thread_id).to be_present
    expect(reply.message).not_to include("@Alice")
    expect(connection.refs.first.failure_message_id).to be_nil
  end

  it "mentions only visible channel members with matching logins" do
    channel.user_chat_channel_memberships.where(user: alice).delete_all
    repo_process(connection, repo_parse(connection, "github_push", "push"))
    workflow
    announce
    expect(
      Chat::Message.where(chat_channel: channel).sole.message
    ).not_to include("@Alice")
  end

  it "keeps non-default and PR CI quiet" do
    workflow(head_branch: "feature")
    workflow(pull_requests: [{ "number" => 8 }])
    announce
    expect(Chat::Message.where(chat_channel: channel).count).to eq(0)
    expect(connection.refs.pluck(:ref_name)).to contain_exactly(
      "feature",
      "pr/8"
    )
  end

  it "coalesces loud events and prefers releases to matching tags" do
    repo_process(connection, repo_parse(connection, "github_tag", "push"))
    repo_process(
      connection,
      repo_parse(connection, "github_release", "release")
    )
    repo_process(connection, repo_parse(connection, "github_issues", "issues"))
    expect(Chat::Message.where(chat_channel: channel).count).to eq(0)
    announce
    message = Chat::Message.where(chat_channel: channel, user: bot).sole
    expect(message.message).to include("Version 1", "Bug in solver")
    expect(Nokogiri::HTML5.fragment(message.cooked).text).to include(
      "sim-tools"
    )
    expect(message.message).not_to include("Tag v1.0")
    expect(connection.events.pluck(:chat_message_id).uniq).to eq([message.id])
    announce
    expect(Chat::Message.where(chat_channel: channel).count).to eq(1)
  end

  it "deletes PR refs when they close" do
    repo_process(
      connection,
      repo_parse(connection, "github_pull_request", "pull_request")
    )
    expect(connection.refs.pluck(:ref_name)).to eq(["pr/8"])
    repo_process(
      connection,
      repo_parse(
        connection,
        "github_pull_request",
        "pull_request",
        { "action" => "closed" }
      )
    )
    expect(connection.refs.count).to eq(0)
  end

  it "skips queued announcements after the channel closes" do
    repo_process(connection, repo_parse(connection, "github_issues", "issues"))
    channel.update!(status: :archived)
    announce
    expect(Chat::Message.where(chat_channel: channel).count).to eq(0)
  end

  it "escapes titles so webhooks cannot mention everyone" do
    repo_process(
      connection,
      repo_parse(
        connection,
        "github_issues",
        "issues",
        { "issue" => { "title" => "@all <script> **title**" } }
      )
    )
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    expect(message.message).not_to include("@all", "<script>")
    expect(message.message).to include("＠all", "&lt;script&gt;")
  end
  it "preserves coalesced text when editing after event pruning" do
    repo_process(connection, repo_parse(connection, "github_issues", "issues"))
    repo_process(connection, repo_parse(connection, "github_push", "push"))
    workflow
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    connection.events.delete_all
    workflow(status: "success", run_attempt: 2)
    announce
    expect(message.reload.message).to include(
      "Bug in solver",
      "fixed in aaaaaaaa"
    )
  end

  it "avoids mentioning an invisible former channel member" do
    group = Fabricate(:group)
    channel.chatable.set_permissions(group => :full)
    channel.chatable.save!
    repo_process(connection, repo_parse(connection, "github_push", "push"))
    workflow
    announce
    expect(
      Chat::Message.where(chat_channel: channel).sole.message
    ).not_to include("@Alice")
  end

  it "posts to a connected private channel with scoped bot access" do
    group = Fabricate(:group)
    channel.chatable.set_permissions(group => :full)
    channel.chatable.save!
    repo_process(connection, repo_parse(connection, "github_issues", "issues"))
    announce
    expect(Chat::Message.where(chat_channel: channel, user: bot).count).to eq(1)
    guardian = DiscourseRepoActivity::BotGuardian.new(connection)
    other = Fabricate(:chat_channel)
    expect(guardian.can_preview_chat_channel?(other)).to eq(false)
    expect(guardian.can_post_in_chatable?(other.chatable)).to eq(false)
    expect(bot.reload.staff?).to eq(false)
    expect(group.group_users.exists?(user: bot)).to eq(false)
  end

  it "coalesces a quick failure and recovery without losing the alert" do
    repo_process(connection, repo_parse(connection, "github_push", "push"))
    workflow
    workflow(status: "success", run_attempt: 2)
    announce
    messages = Chat::Message.where(chat_channel: channel).order(:id)
    expect(messages.count).to eq(2)
    expect(messages.first.message).to include("fixed in aaaaaaaa")
    expect(messages.last.in_reply_to_id).to eq(messages.first.id)
    expect(messages.map(&:message).join).not_to include("@Alice")
  end
  it "fits busy announcement windows within Chat's length limit" do
    SiteSetting.chat_maximum_message_length = 1000
    6.times do
      repo_process(
        connection,
        repo_parse(
          connection,
          "github_issues",
          "issues",
          { "issue" => { "title" => "A" * 400 } }
        )
      )
    end
    workflow
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    expect(message.message.length).to be <= 1000
    expect(message.message).to include("CI failing", "more events")
    expect(connection.events.where(chat_message_id: message.id).count).to eq(7)
  end
end
