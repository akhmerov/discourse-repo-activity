# frozen_string_literal: true

RSpec.describe DiscourseRepoActivity::Announcer do
  fab!(:user)
  fab!(:channel, :chat_channel)
  fab!(:connection) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: user,
      forge: "gitlab",
      host: "gitlab.example.org",
      repo_path: "research/tools",
      default_branch: "main",
    )
  end

  before do
    SiteSetting.chat_enabled = true
    SiteSetting.repo_activity_enabled = true
    channel.add(user)
  end

  def announce
    DiscourseRepoActivity::Announcer.new(connection).announce
  end

  def pipeline(sha, state, id)
    repo_process(
      connection,
      repo_parse(
        connection,
        "gitlab_pipeline",
        "Pipeline Hook",
        {
          "object_attributes" => {
            "sha" => sha,
            "status" => state,
            "id" => id,
            "url" => "https://gitlab.example.org/research/tools/-/pipelines/#{id}",
          },
        },
      ),
    )
  end

  it "does not attribute a GitLab release to the commit author" do
    data = repo_parse(connection, "gitlab_release", "Release Hook")
    expect(data[:actor]).to be_blank
    repo_process(connection, data)
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    fragment = Nokogiri::HTML5.fragment(message.cooked)
    expect(fragment.text).to include("Release: Version 1")
    expect(fragment.text).not_to include(" by ", "Commit author")
  end

  it "omits empty actors for any durable announcement kind" do
    %w[release tag pr_opened pr_merged issue_opened].each do |kind|
      event =
        DiscourseRepoActivity::Event.new(kind: kind, actor_login: "  ", summary: { title: "Title" })
      raw =
        DiscourseRepoActivity::Announcer.new(connection).send(
          :render_events,
          [event],
          mention: false,
        )
      expect(raw).not_to include(" by ")
    end
  end

  it "links initial and edited failures to their pipeline and recovery to the commit" do
    pipeline("a" * 40, "failed", 101)
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    first = Nokogiri::HTML5.fragment(message.cooked).at_css("a")
    expect(first.text).to eq("aaaaaaaa")
    expect(first["href"]).to eq("https://gitlab.example.org/research/tools/-/pipelines/101")
    pipeline("b" * 40, "failed", 102)
    announce
    expect(Chat::Message.where(chat_channel: channel).count).to eq(1)
    edited = Nokogiri::HTML5.fragment(message.reload.cooked)
    expect(edited.css("a").map { |a| [a.text, a["href"]] }).to eq(
      [%w[bbbbbbbb https://gitlab.example.org/research/tools/-/pipelines/102]],
    )
    result =
      Chat::CreateMessage.call(
        guardian: user.guardian,
        params: {
          chat_channel_id: channel.id,
          message: "Checking this",
          in_reply_to_id: message.id,
        },
        options: {
          force_thread: true,
        },
      )
    expect(result).to be_success
    pipeline("b" * 40, "success", 103)
    announce
    fixed = Nokogiri::HTML5.fragment(message.reload.cooked)
    expect(fixed.text).to include("fixed in bbbbbbbb")
    expect(fixed.text).not_to include("CI failing")
    expect(fixed.at_css("a")["href"]).to eq(
      "https://gitlab.example.org/research/tools/-/commit/#{"b" * 40}",
    )
    reply =
      Chat::Message
        .where(chat_channel: channel, user: DiscourseRepoActivity::Bot.user)
        .order(:id)
        .last
    expect(reply.in_reply_to_id).to eq(message.id)
    expect(reply.cooked).to include("/-/commit/#{"b" * 40}")
  end

  it "preserves unlinked failure rewriting when the run URL is absent" do
    pipeline("a" * 40, "failed", 101)
    connection
      .events
      .where(kind: "failure")
      .each { |event| event.update!(summary: event.summary.except("url")) }
    announce
    message = Chat::Message.where(chat_channel: channel).sole
    expect(message.message).to include("CI failing on main (aaaaaaaa)")
    pipeline("b" * 40, "failed", 102)
    announce
    expect(message.reload.message).to include("CI failing on main ([bbbbbbbb]")
  end

  it "uses channel-local qualified names only for collisions, including equal paths on two hosts" do
    other =
      DiscourseRepoActivity::Connection.create!(
        chat_channel: channel,
        created_by: user,
        forge: "github",
        host: "github.com",
        repo_path: "acme/tools",
      )
    unique =
      DiscourseRepoActivity::Connection.create!(
        chat_channel: channel,
        created_by: user,
        forge: "github",
        host: "github.com",
        repo_path: "acme/unique",
      )
    labels = DiscourseRepoActivity::Connection.display_labels([connection, other, unique])
    expect(labels).to eq(
      connection.id => "research/tools",
      other.id => "acme/tools",
      unique.id => "unique",
    )
    repo_process(connection, repo_parse(connection, "gitlab_release", "Release Hook"))
    announce
    expect(
      Nokogiri::HTML5
        .fragment(Chat::Message.where(chat_channel: channel).sole.cooked)
        .at_css("strong")
        .text,
    ).to eq("research/tools")
    other.update!(repo_path: "research/tools")
    expect(DiscourseRepoActivity::Connection.display_labels([connection, other])).to eq(
      connection.id => "gitlab.example.org/research/tools",
      other.id => "github.com/research/tools",
    )
    other.update!(chat_channel: Fabricate(:chat_channel))
    expect(
      DiscourseRepoActivity::Connection.display_labels([connection, other])[connection.id],
    ).to eq("tools")
  end
end
