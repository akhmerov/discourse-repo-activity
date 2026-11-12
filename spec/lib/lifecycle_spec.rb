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
            "workflow_id" => { "Tests" => 7, "Lint" => 8, "Build" => 9 }.fetch(
              name,
              10
            ),
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
    expect(message.reload.message).to include("fixed in ` bbbbbbbb `")
    reply =
      Chat::Message.where(chat_channel: channel, user: bot).order(:id).last
    expect(reply.in_reply_to_id).to eq(message.id)
    expect(reply.thread_id).to be_present
    expect(reply.message).not_to include("@Alice")
    expect(connection.refs.first.failure_message_id).to be_nil
  end

  it "retains the incident when recovery and a new failure share the first announcement" do
    workflow(id: 200)
    workflow(status: "success", id: 201)
    workflow(sha: "b" * 40, id: 202)
    announce
    message = Chat::Message.where(chat_channel: channel, user: bot).sole
    expect(message.message).to include("CI failing", "bbbbbbbb")
    expect(connection.refs.first.failing_since).to be_present
    workflow(sha: "b" * 40, status: "success", id: 203)
    announce
    expect(message.reload.message).to include("fixed in ` bbbbbbbb `")
    reply = Chat::Message.where(chat_channel: channel, user: bot).order(:id).last
    expect(reply.in_reply_to_id).to eq(message.id)
    expect(reply.thread_id).to be_present
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
    workflow(
      pull_requests: [{ "number" => 8, "base" => { "repo" => { "id" => 42 } } }]
    )
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
    expect(
      Nokogiri::HTML5.fragment(message.cooked).css(".mention, script")
    ).to be_empty
    expect(Nokogiri::HTML5.fragment(message.cooked).text).to include(
      "@all",
      "<script>"
    )
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
      "fixed in ` aaaaaaaa `"
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

  it "silences a failure and recovery completed before the first announcement" do
    repo_process(connection, repo_parse(connection, "github_push", "push"))
    workflow
    workflow(status: "success", run_attempt: 2)
    announce
    expect(Chat::Message.where(chat_channel: channel)).to be_empty
    expect(
      connection.events.where(loud: true, chat_message_id: nil)
    ).to be_empty
    expect(connection.refs.first.failing_since).to be_nil
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

  it "drops recovery when its failure message was deleted and clears the incident" do
    workflow
    announce
    Chat::Message.where(chat_channel: channel).sole.trash!
    workflow(status: "success", run_attempt: 2)
    announce
    expect(connection.refs.first.attributes).to include(
      "failing_since" => nil,
      "failure_message_id" => nil
    )
    workflow(status: "success", run_attempt: 3)
    announce
    expect(Chat::Message.where(chat_channel: channel).count).to eq(0)
    expect(
      connection.events.where(
        kind: "recovery",
        loud: true,
        chat_message_id: nil
      )
    ).to be_empty
  end

  it "updates state with quiet CI off and gates failure and recovery independently" do
    connection.update!(enabled_events: %w[failure recovery])
    workflow
    expect(connection.refs.first.ci_state).to eq("failed")
    expect(connection.events.order(:id).pluck(:kind)).to eq(["failure"])
    announce
    workflow(status: "success", run_attempt: 2)
    announce
    expect(connection.events.order(:id).pluck(:kind)).to eq(
      %w[failure recovery]
    )
    expect(connection.refs.first.failing_since).to be_nil
  end

  it "clears recovery without an alert when failure posting is off" do
    connection.update!(enabled_events: %w[ci recovery])
    workflow
    announce
    workflow(status: "success", run_attempt: 2)
    announce
    expect(Chat::Message.where(chat_channel: channel)).to be_empty
    expect(connection.refs.first.failing_since).to be_nil
    workflow(status: "success", run_attempt: 3)
    expect(connection.events.where(kind: "recovery").count).to eq(1)
  end

  it "keeps workflows with duplicate names independent and cancellations neutral" do
    workflow(workflow_id: 21)
    workflow(workflow_id: 22, status: "success")
    expect(connection.refs.first.ci_runs.keys).to contain_exactly("21", "22")
    expect(connection.refs.first.ci_state).to eq("failed")
    connection.events.delete_all
    connection.refs.delete_all
    %w[cancelled skipped].each { |status| workflow(status: status) }
    expect(
      connection.refs.first.ci_runs.values.map { |run| run["state"] }
    ).to eq(["neutral"])
    expect(connection.events.where(loud: true)).to be_empty
    expect(connection.refs.first.ci_state).to eq("neutral")
  end

  it "uses the failing event sha if a newer push arrives before announcement" do
    workflow
    repo_process(
      connection,
      repo_parse(connection, "github_push", "push", "after" => "b" * 40)
    )
    announce
    expect(Chat::Message.where(chat_channel: channel).sole.message).to include(
      "aaaaaaaa"
    )
    expect(
      Chat::Message.where(chat_channel: channel).sole.message
    ).not_to include("bbbbbbbb")
  end

  it "re-enqueues after a lost job expires even with an older pending event" do
    repo_process(connection, repo_parse(connection, "github_issues", "issues"))
    key = "repo-activity:announce:#{connection.id}"
    expect(Discourse.redis.ttl(key)).to be_between(1, 180)
    Discourse.redis.del(key)
    expect {
      repo_process(
        connection,
        repo_parse(connection, "github_issues", "issues")
      )
    }.to change { Jobs::RepoActivityAnnounce.jobs.size }.by(1)
  end

  it "discards pending alerts on disable before re-enable" do
    workflow
    connection.update!(enabled: false)
    connection.update!(enabled: true)
    announce
    expect(Chat::Message.where(chat_channel: channel)).to be_empty
    expect(connection.events.where(loud: true)).to be_empty
    expect(connection.refs.first.failing_since).to be_present
  end

  it "cooks untrusted titles without autolinks, hashtags, mentions or HTML" do
    title =
      "Don't https://example.com www.example.com #tag @all `code` **bold** <img src=x>"
    text = described_class.new(connection).send(:title_text, title)
    cooked = Chat::Message.cook(text, user_id: bot.id, chat_channel: channel)
    fragment = Nokogiri::HTML5.fragment(cooked)
    expect(
      fragment.css("a, img, script, .mention, .hashtag, .onebox")
    ).to be_empty
    expect(fragment.text).to include(
      "Don't",
      "`code`",
      "**bold**",
      "<img src=x>"
    )
    expect(fragment.text).not_to include("&#39;")
    linked =
      described_class.new(connection).send(
        :link,
        title,
        "https://github.com/acme/sim-tools/issues/1"
      )
    fragment =
      Nokogiri::HTML5.fragment(
        Chat::Message.cook(linked, user_id: bot.id, chat_channel: channel)
      )
    expect(fragment.css("a").map { |a| a["href"] }).to eq(
      ["https://github.com/acme/sim-tools/issues/1"]
    )
    expect(fragment.css("img, script, .mention, .hashtag, .onebox")).to be_empty
  end

  it "keeps quiet CI records and clears incidents when recovery alerts are off" do
    connection.update!(enabled_events: %w[ci])
    workflow
    expect(connection.refs.first.ci_state).to eq("failed")
    expect(connection.events.order(:id).pluck(:kind)).to eq(["ci"])
    workflow(status: "success", run_attempt: 2)
    expect(connection.refs.first.failing_since).to be_nil
    expect(connection.events.order(:id).pluck(:kind)).to eq(%w[ci ci])
    announce
    expect(Chat::Message.where(chat_channel: channel)).to be_empty
  end

  it "uses the failure event sha when editing an existing alert after a newer push" do
    workflow
    announce
    workflow(sha: "b" * 40, id: 114)
    repo_process(
      connection,
      repo_parse(connection, "github_push", "push", "after" => "c" * 40)
    )
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    expect(message.message).to include("bbbbbbbb")
    expect(message.message).not_to include("cccccccc")
  end

  it "does not announce recovery when a failed run is cancelled" do
    workflow
    announce
    workflow(status: "cancelled", run_attempt: 2)
    announce
    expect(connection.events.where(kind: "recovery")).to be_empty
    expect(Chat::Message.where(chat_channel: channel).count).to eq(1)
  end

  it "silences a same-window failure when green with recovery disabled" do
    connection.update!(enabled_events: %w[failure ci issue_opened])
    workflow
    workflow(status: "success", run_attempt: 2)
    repo_process(connection, repo_parse(connection, "github_issues", "issues"))
    announce
    expect(Chat::Message.where(chat_channel: channel).sole.message).to include(
      "Bug in solver"
    )
    expect(
      Chat::Message.where(chat_channel: channel).sole.message
    ).not_to include("CI failing")
    expect(
      connection.events.where(kind: "failure", loud: true, chat_message_id: nil)
    ).to be_empty
  end

  it "preserves the existing failure SHA when an edit has no failure event SHA" do
    workflow
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    workflow(status: "success", run_attempt: 2)
    connection.update!(enabled_events: %w[failure])
    announce
    expect(message.reload.message).to include("aaaaaaaa")
    expect(message.message).not_to include("()")
  end

  it "keeps posted incident state through transient channel inactivity" do
    workflow
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    workflow(id: 113)
    channel.update!(status: :closed)
    announce
    expect(connection.refs.first.failure_message_id).to eq(message.id)
    expect(connection.refs.first.failing_since).to be_present
    channel.update!(status: :open)
    workflow(id: 114)
    announce
    expect(Chat::Message.where(chat_channel: channel).count).to eq(1)
    workflow(status: "success", id: 114, run_attempt: 2)
    announce
    expect(
      Chat::Message.where(chat_channel: channel).order(:id).last.in_reply_to_id
    ).to eq(message.id)
  end

  it "cooks display and branch names as literal code without links or emoji" do
    name = "evil.com www.evil.com https://evil.com :smile: @all #tag `code`"
    connection.update!(display_name: name)
    workflow
    ref = connection.refs.first
    ref.update!(ref_name: name)
    connection
      .events
      .where(kind: "failure")
      .each do |event|
        event.update!(summary: event.summary.merge("ref" => name))
      end
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    fragment =
      Nokogiri::HTML5.fragment(
        Chat::Message.cook(
          message.message,
          user_id: bot.id,
          chat_channel: channel
        )
      )
    expect(
      fragment.css("a, img, .emoji, .mention, .hashtag, .onebox")
    ).to be_empty
    expect(fragment.css("code").map(&:text).join).to include(name)
    expect(message.message).not_to include("\u200b")
  end

  it "keeps newline-containing display names inside the code span" do
    name = "x\n\n@all [evil](https://evil.example) :smile:\n# h\n> q"
    text = described_class.new(connection).send(:title_text, name)
    fragment =
      Nokogiri::HTML5.fragment(
        Chat::Message.cook(text, user_id: bot.id, chat_channel: channel)
      )
    expect(fragment.css("a, img, .emoji, .mention, h1, blockquote")).to be_empty
    expect(fragment.css("code").size).to eq(1)
  end
end
