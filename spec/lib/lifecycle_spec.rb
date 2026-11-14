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
      default_branch: "main",
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
            "workflow_id" => { "Tests" => 7, "Lint" => 8, "Build" => 9 }.fetch(name, 10),
            "conclusion" => status,
            "head_sha" => sha,
          }.merge(extra.transform_keys(&:to_s)),
        },
      ),
    )
  end

  def human_reply(message)
    Chat::CreateMessage.call(
      guardian: alice.guardian,
      params: {
        chat_channel_id: channel.id,
        message: "I am investigating this.",
        in_reply_to_id: message.id,
      },
      options: {
        force_thread: true,
      },
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
    repo_process(connection, repo_parse(connection, "github_push", "push", { "after" => "b" * 40 }))
    workflow(sha: "b" * 40, id: 114)
    announce
    expect(Chat::Message.where(chat_channel: channel, user: bot).count).to eq(1)
    expect(message.reload.message).to include("bbbbbbbb")
    human_reply(message)
    workflow(sha: "b" * 40, status: "success", id: 114, run_attempt: 2)
    announce
    expect(message.reload.message).to include(
      "fixed in [bbbbbbbb](https://github.com/acme/sim-tools/commit/#{"b" * 40})",
    )
    reply = Chat::Message.where(chat_channel: channel, user: bot).order(:id).last
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
    human_reply(message)
    workflow(sha: "b" * 40, status: "success", id: 203)
    announce
    expect(message.reload.message).to include(
      "fixed in [bbbbbbbb](https://github.com/acme/sim-tools/commit/#{"b" * 40})",
    )
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
    expect(Chat::Message.where(chat_channel: channel).sole.message).not_to include("@Alice")
  end

  it "keeps non-default and PR CI quiet" do
    workflow(head_branch: "feature")
    workflow(pull_requests: [{ "number" => 8, "base" => { "repo" => { "id" => 42 } } }])
    announce
    expect(Chat::Message.where(chat_channel: channel).count).to eq(0)
    expect(connection.refs.pluck(:ref_name)).to contain_exactly("feature", "pr/8")
  end

  it "coalesces loud events and prefers releases to matching tags" do
    repo_process(connection, repo_parse(connection, "github_tag", "push"))
    repo_process(connection, repo_parse(connection, "github_release", "release"))
    repo_process(connection, repo_parse(connection, "github_issues", "issues"))
    expect(Chat::Message.where(chat_channel: channel).count).to eq(0)
    announce
    message = Chat::Message.where(chat_channel: channel, user: bot).sole
    expect(message.message).to include("Version 1", "Bug in solver")
    expect(Nokogiri::HTML5.fragment(message.cooked).text).to include("sim-tools")
    expect(message.message).not_to include("Tag v1.0")
    expect(connection.events.pluck(:chat_message_id).uniq).to eq([message.id])
    announce
    expect(Chat::Message.where(chat_channel: channel).count).to eq(1)
  end

  it "deletes PR refs when they close" do
    repo_process(connection, repo_parse(connection, "github_pull_request", "pull_request"))
    expect(connection.refs.pluck(:ref_name)).to eq(["pr/8"])
    repo_process(
      connection,
      repo_parse(connection, "github_pull_request", "pull_request", { "action" => "closed" }),
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
        { "issue" => { "title" => "@all <script> **title**" } },
      ),
    )
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    expect(Nokogiri::HTML5.fragment(message.cooked).css(".mention, script")).to be_empty
    expect(Nokogiri::HTML5.fragment(message.cooked).text).to include("@ all", "<script>")
  end

  it "preserves coalesced text when editing after event pruning" do
    repo_process(connection, repo_parse(connection, "github_issues", "issues"))
    repo_process(connection, repo_parse(connection, "github_push", "push"))
    workflow
    announce
    message =
      Chat::Message.where(chat_channel: channel).where("message LIKE ?", "%CI failing%").sole
    human_reply(message)
    connection.events.delete_all
    workflow(status: "success", run_attempt: 2)
    announce
    expect(message.reload.message).to include(
      "fixed in [aaaaaaaa](https://github.com/acme/sim-tools/commit/#{"a" * 40})",
    )
    expect(
      Chat::Message.where(chat_channel: channel).where("message LIKE ?", "%Bug in solver%"),
    ).to exist
  end

  it "avoids mentioning an invisible former channel member" do
    group = Fabricate(:group)
    channel.chatable.set_permissions(group => :full)
    channel.chatable.save!
    repo_process(connection, repo_parse(connection, "github_push", "push"))
    workflow
    announce
    expect(Chat::Message.where(chat_channel: channel).sole.message).not_to include("@Alice")
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
    expect(connection.events.where(loud: true, chat_message_id: nil)).to be_empty
    expect(connection.refs.first.failing_since).to be_nil
  end

  it "fits busy announcement windows within Chat's length limit" do
    SiteSetting.chat_maximum_message_length = 1000
    6.times do
      repo_process(
        connection,
        repo_parse(connection, "github_issues", "issues", { "issue" => { "title" => "A" * 400 } }),
      )
    end
    workflow
    announce
    messages = Chat::Message.where(chat_channel: channel)
    expect(messages.count).to eq(2)
    expect(messages.map { |m| m.message.length }.max).to be <= 1000
    expect(messages.map(&:message).join).to include("CI failing", "more events")
    expect(connection.events.where.not(chat_message_id: nil).count).to eq(7)
  end

  it "drops recovery when its failure message was deleted and clears the incident" do
    workflow
    announce
    Chat::Message.where(chat_channel: channel).sole.trash!
    workflow(status: "success", run_attempt: 2)
    announce
    expect(connection.refs.first.attributes).to include(
      "failing_since" => nil,
      "failure_message_id" => nil,
    )
    workflow(status: "success", run_attempt: 3)
    announce
    expect(Chat::Message.where(chat_channel: channel).count).to eq(0)
    expect(connection.events.where(kind: "recovery", loud: true, chat_message_id: nil)).to be_empty
  end

  it "keeps workflows with duplicate names independent and cancellations neutral" do
    workflow(workflow_id: 21)
    workflow(workflow_id: 22, status: "success")
    expect(connection.refs.first.ci_runs.keys).to contain_exactly("21", "22")
    expect(connection.refs.first.ci_state).to eq("failed")
    connection.events.delete_all
    connection.refs.delete_all
    %w[cancelled skipped].each { |status| workflow(status: status) }
    expect(connection.refs.first.ci_runs.values.map { |run| run["state"] }).to eq(["neutral"])
    expect(connection.events.where(loud: true)).to be_empty
    expect(connection.refs.first.ci_state).to eq("neutral")
  end

  it "uses the failing event sha if a newer push arrives before announcement" do
    workflow
    repo_process(connection, repo_parse(connection, "github_push", "push", "after" => "b" * 40))
    announce
    expect(Chat::Message.where(chat_channel: channel).sole.message).to include("aaaaaaaa")
    expect(Chat::Message.where(chat_channel: channel).sole.message).not_to include("bbbbbbbb")
  end

  it "re-enqueues after a lost job expires even with an older pending event" do
    repo_process(connection, repo_parse(connection, "github_issues", "issues"))
    key = "repo-activity:announce:#{connection.id}"
    expect(Discourse.redis.ttl(key)).to be_between(1, 180)
    Discourse.redis.del(key)
    expect {
      repo_process(connection, repo_parse(connection, "github_issues", "issues"))
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
    title = "Don't https://example.com www.example.com #tag @all `code` **bold** <img src=x>"
    text = described_class.new(connection).send(:title_text, title)
    cooked = Chat::Message.cook(text, user_id: bot.id, chat_channel: channel)
    fragment = Nokogiri::HTML5.fragment(cooked)
    expect(fragment.css("a, img, script, .mention, .hashtag, .onebox")).to be_empty
    expect(fragment.text).to include("Don't", "`code`", "**bold**", "<img src=x>")
    expect(fragment.text).not_to include("&#39;")
    linked =
      described_class.new(connection).send(
        :link,
        title,
        "https://github.com/acme/sim-tools/issues/1",
      )
    fragment =
      Nokogiri::HTML5.fragment(Chat::Message.cook(linked, user_id: bot.id, chat_channel: channel))
    expect(fragment.css("a").map { |a| a["href"] }).to eq(
      ["https://github.com/acme/sim-tools/issues/1"],
    )
    expect(fragment.css("img, script, .mention, .hashtag, .onebox")).to be_empty
  end

  it "uses the failure event sha when editing an existing alert after a newer push" do
    workflow
    announce
    workflow(sha: "b" * 40, id: 114)
    repo_process(connection, repo_parse(connection, "github_push", "push", "after" => "c" * 40))
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
    human_reply(message)
    workflow(status: "success", id: 114, run_attempt: 2)
    announce
    expect(Chat::Message.where(chat_channel: channel).order(:id).last.in_reply_to_id).to eq(
      message.id,
    )
  end

  it "cooks display and branch names as readable text without links or emoji" do
    name = "evil.com www.evil.com https://evil.com :smile: @all #tag `code`"
    connection.update!(display_name: name)
    workflow
    ref = connection.refs.first
    ref.update!(ref_name: name)
    connection
      .events
      .where(kind: "failure")
      .each { |event| event.update!(summary: event.summary.merge("ref" => name)) }
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    fragment =
      Nokogiri::HTML5.fragment(
        Chat::Message.cook(message.message, user_id: bot.id, chat_channel: channel),
      )
    expect(fragment.css("a").map { |a| a["href"] }).to eq(
      ["https://github.com/acme/sim-tools/actions/runs/112"],
    )
    expect(fragment.css("strong a, img, .emoji, .mention, .hashtag, .onebox")).to be_empty
    expect(fragment.css("code")).to be_empty
    expect(fragment.text).to include("evil.com", "@ all", ": smile:")
    expect(message.message).not_to include("\u200b")
  end

  it "neutralizes newline-containing display names as readable text" do
    name = "x\n\n@all [evil](https://evil.example) :smile:\n# h\n> q"
    text = described_class.new(connection).send(:title_text, name)
    fragment =
      Nokogiri::HTML5.fragment(Chat::Message.cook(text, user_id: bot.id, chat_channel: channel))
    expect(fragment.css("a, img, .emoji, .mention, h1, blockquote")).to be_empty
    expect(fragment.css("code")).to be_empty
  end

  it "trashes a recovered alert, removes unread activity and keeps the incident in the stream" do
    baseline = Chat::Message.create!(chat_channel: channel, user: alice, message: "Before CI")
    channel.update!(last_message: baseline)
    channel.membership_for(alice).update!(last_read_message: baseline)
    workflow
    announce
    alert = Chat::Message.where(user: bot, chat_channel: channel).sole
    expect(channel.reload.last_message_id).to eq(alert.id)
    workflow(status: "success", run_attempt: 2)
    announce
    expect(alert.reload).to be_trashed
    expect(alert.deleted_by_id).to eq(bot.id)
    expect(channel.reload.last_message_id).to eq(baseline.id)
    expect(channel.membership_for(alice).reload.last_read_message_id).to eq(channel.last_message_id)
    expect(Chat::Message.where(in_reply_to_id: alert.id)).to be_empty
    expect(connection.events.where(kind: "recovery")).to exist
  end

  it "restores and fixes an alert when a human resolved its parent immediately before deletion" do
    workflow
    announce
    alert = Chat::Message.where(user: bot, chat_channel: channel).sole
    workflow(status: "success", run_attempt: 2)
    announce
    expect(alert.reload).to be_trashed
    # Model the in-flight service which fetched the reply before deletion.
    reply =
      Chat::Message.create!(
        chat_channel: channel,
        user: alice,
        in_reply_to_id: alert.id,
        message: "I was investigating",
      )
    DiscourseEvent.trigger(:chat_message_created, reply, channel, alice, {})
    expect(alert.reload).not_to be_trashed
    expect(alert.message).to include(
      "fixed in [aaaaaaaa](https://github.com/acme/sim-tools/commit/#{"a" * 40})",
    )
    expect(Chat::Message.where(in_reply_to_id: alert.id, user: bot)).to exist
  end

  it "updates a push's CI summary without adding branch CI to the stream" do
    repo_process(
      connection,
      repo_parse(connection, "github_push", "push", "ref" => "refs/heads/feature"),
    )
    workflow(head_branch: "feature", status: "success")
    expect(connection.events.find_by!(kind: "push").summary["ci_state"]).to eq("success")
    stream = DiscourseRepoActivity::Snapshot.stream(channel)[:stream]
    expect(stream.size).to eq(1)
    expect(stream.sole["kind"]).to eq("push")
  end

  it "renders ordinary names and linked titles without code spans and caps repeated PRs" do
    8.times do
      repo_process(connection, repo_parse(connection, "github_pull_request", "pull_request"))
    end
    announce
    message = Chat::Message.where(chat_channel: channel, user: bot).sole
    fragment = Nokogiri::HTML5.fragment(message.cooked)
    expect(fragment.css("code")).to be_empty
    expect(fragment.css("strong").text).to eq("sim-tools")
    expect(fragment.css("a").size).to eq(3)
    expect(fragment.text).to include("+ 5 more PRs/MRs opened")
  end

  it "neutralizes the extended cooker trigger matrix" do
    [
      "@all @Alice #general :smile:",
      "https://evil.com www.evil.com evil.com",
      "[click](https://evil.com) <img src=x onerror=alert(1)>",
      "a\n\n@all\n# heading",
      "xn--evil.example 😀 :heart:",
    ].each do |title|
      aggregate_failures(title) do
        text = described_class.new(connection).send(:title_text, title)
        fragment =
          Nokogiri::HTML5.fragment(Chat::Message.cook(text, user_id: bot.id, chat_channel: channel))
        expect(
          fragment.css("a, img, script, code, .mention, .hashtag, .emoji, .onebox"),
        ).to be_empty
        expect(text).not_to match(/[\u200b\u200c\u200d\u2060]/)
      end
    end
  end

  it "keeps one recovery in the stream while subsequent green pushes await announcement" do
    workflow
    announce
    workflow(status: "success", run_attempt: 2)
    repo_process(connection, repo_parse(connection, "github_push", "push", "after" => "b" * 40))
    workflow(sha: "b" * 40, status: "success", id: 114)
    expect(connection.events.where(kind: "recovery").count).to eq(1)
    announce
    workflow(sha: "b" * 40, id: 115)
    workflow(sha: "b" * 40, status: "success", id: 116)
    expect(connection.events.where(kind: "recovery").count).to eq(2)
  end

  it "renders issue numbers as literal identifiers without tag links" do
    repo_process(
      connection,
      repo_parse(connection, "github_issues", "issues", "issue" => { "number" => "2024" }),
    )
    announce
    fragment = Nokogiri::HTML5.fragment(Chat::Message.where(chat_channel: channel).sole.cooked)
    expect(fragment.css("a").map(&:text).join).to include("#2024")
    expect(fragment.css(".hashtag, .mention")).to be_empty
  end

  it "neutralizes every emoji shortcut and unlinked date markup" do
    [
      *Emoji.translations.keys,
      "[date=2026-11-13 timezone=Europe/Amsterdam]",
      "safe\u202Ename\u200B",
    ].each do |title|
      text = described_class.new(connection).send(:title_text, title)
      fragment =
        Nokogiri::HTML5.fragment(Chat::Message.cook(text, user_id: bot.id, chat_channel: channel))
      expect(fragment.css(".emoji, img, .discourse-local-date")).to be_empty
      expect(text).not_to match(/\p{Cf}/)
    end
  end

  it "caps titles and skips oversized lines while keeping short later events" do
    announcer = described_class.new(connection)
    expect(announcer.send(:title_text, "x" * 1000).length).to be <= 310
    SiteSetting.chat_maximum_message_length = 1000
    expect(announcer.send(:fit_message, "Repo", ["x" * 2000, "Short issue"], [])).to include(
      "Short issue",
      "1 more events",
    )
  end

  it "fixes the alert and continues announcements when native trash refuses" do
    workflow
    announce
    alert = Chat::Message.where(chat_channel: channel).sole
    Chat::TrashMessage.stubs(:call).returns(stub(success?: false, failure?: true))
    workflow(status: "success", run_attempt: 2)
    expect { announce }.not_to raise_error
    expect(alert.reload.message).to include("fixed in")
    expect(connection.refs.first.failure_message_id).to be_nil
    repo_process(connection, repo_parse(connection, "github_issues", "issues"))
    announce
    expect(Chat::Message.where(chat_channel: channel).order(:id).last.message).to include(
      "Bug in solver",
    )
  end

  it "locks a live incident even after its failure event was pruned" do
    workflow
    announce
    alert = Chat::Message.where(chat_channel: channel).sole
    connection.events.delete_all
    queries = track_sql_queries { expect(human_reply(alert)).to be_success }
    expect(queries.grep(/repo_activity_connections.*FOR UPDATE/)).to be_present
    expect(queries.grep(/chat_channels.*FOR UPDATE/)).to be_present
  end
end
