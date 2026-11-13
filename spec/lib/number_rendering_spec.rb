# frozen_string_literal: true

RSpec.describe DiscourseRepoActivity::Announcer do
  fab!(:user)
  fab!(:channel, :chat_channel)

  it "keeps native forge identifiers inside explicit links with real hashtag matches present" do
    SiteSetting.chat_enabled = true
    SiteSetting.tagging_enabled = true
    Fabricate(:tag, name: "244")
    control =
      Nokogiri::HTML5.fragment(Chat::Message.cook("#244", user_id: user.id, chat_channel: channel))
    expect(control.css("a.hashtag-cooked")).not_to be_empty
    %w[#244 !244].each do |identifier|
      cooked =
        Chat::Message.cook(
          "[#{identifier} Title](https://github.com/acme/repo/pull/244)",
          user_id: user.id,
          chat_channel: channel,
        )
      fragment = Nokogiri::HTML5.fragment(cooked)
      expect(fragment.css("a").map(&:text)).to eq(["#{identifier} Title"])
      expect(fragment.css("a.hashtag-cooked, .hashtag")).to be_empty
    end
  end

  def rendered(
    forge:,
    kind: "pr_opened",
    number: "244",
    url: "https://github.com/acme/repo/pull/244"
  )
    connection = DiscourseRepoActivity::Connection.new(forge: forge)
    event =
      DiscourseRepoActivity::Event.new(
        kind: kind,
        actor_login: "author",
        summary: {
          number: number,
          title: "Title](javascript:alert(1)) **bold** #244 @all",
          url: url,
        },
      )
    raw = described_class.new(connection).send(:render_events, [event], mention: false)
    Nokogiri::HTML5.fragment(Chat::Message.cook(raw, user_id: user.id, chat_channel: channel))
  end

  it "puts validated native numbers inside the forge link without Markdown injection" do
    SiteSetting.chat_enabled = true
    SiteSetting.tagging_enabled = true
    Fabricate(:tag, name: "244")
    %w[github gitlab].each do |forge|
      %w[pr_opened pr_merged issue_opened].each do |kind|
        url =
          "https://#{forge == "github" ? "github.com" : "gitlab.example.org"}/acme/repo/issues/244"
        fragment = rendered(forge: forge, kind: kind, url: url)
        identifier = forge == "gitlab" && kind != "issue_opened" ? "!244" : "#244"
        expect(fragment.css("a").map { |a| a["href"] }).to eq([url])
        expect(fragment.css("a").sole.text).to start_with("#{identifier} Title")
        expect(fragment.css(".hashtag-cooked, .mention, script, strong")).to be_empty
      end
    end
  end

  it "does not interpolate malformed identifiers into Markdown" do
    fragment = rendered(forge: "github", number: "244](https://injected.invalid)")
    expect(fragment.to_html).not_to include("injected.invalid")
    expect(fragment.css("a").length).to eq(1)
  end

  it "uses a safe literal native identifier when a forge URL is absent" do
    SiteSetting.chat_enabled = true
    SiteSetting.tagging_enabled = true
    Fabricate(:tag, name: "244")
    fragment = rendered(forge: "github", url: nil)
    expect(fragment.css("code").map(&:text)).to eq(["#244"])
    expect(fragment.css("a, .hashtag-cooked")).to be_empty
  end
end
