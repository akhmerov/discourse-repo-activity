# frozen_string_literal: true

RSpec.describe "Repository activity pill" do
  fab!(:user)
  fab!(:channel, :chat_channel)
  fab!(:connection) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: user,
      forge: "github",
      host: "github.com",
      repo_path: "acme/sim-tools",
    )
  end
  fab!(:activity) do
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "push",
      actor_login: "alice",
      summary: {
        title: "Push to main",
        sha: "a" * 40,
      },
    )
  end

  before do
    chat_system_bootstrap
    SiteSetting.repo_activity_enabled = true
    SiteSetting.discourse_workspace_groups_enabled = false if defined?(DiscourseWorkspaceGroups)

    channel.add(user)
    sign_in(user)
  end

  it "opens the popover and resets the new count persistently" do
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__pill", text: "sim-tools")
    expect(page).to have_css(".repo-activity__pill", text: "1 new")
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__event--new", text: "Push to main")
    expect(page).to have_no_css(".repo-activity__pill", text: "1 new")
    page.refresh
    expect(page).to have_css(".repo-activity__pill", text: "sim-tools")
    expect(page).to have_no_css(".repo-activity__pill", text: "1 new")
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__event", text: "Push to main")
    expect(page).to have_no_css(".repo-activity__event--new")
  end

  it "shows the popover as a mobile dialog", mobile: true do
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    find(".repo-activity__pill").click
    expect(page).to have_css(".fk-d-menu-modal .repo-activity__event", text: "Push to main")
    expect(page).to have_no_css(".repo-activity__pill", text: "1 new")
  end

  it "updates the pill live for a new quiet event" do
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__pill", text: "1 new")
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "push",
      summary: {
        title: "Second push",
      },
    )
    DiscourseRepoActivity::Snapshot.publish(channel)
    Jobs::RepoActivityPublish.new.execute(channel_id: channel.id)
    expect(page).to have_css(".repo-activity__pill", text: "2 new")
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__event--new", text: "Second push")
  end

  it "preserves management permission and seen state across shared live updates" do
    user.update!(admin: true)
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__manage")
    expect(page).to have_no_css(".repo-activity__pill", text: "1 new")
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "push",
      summary: {
        title: "Live push",
      },
    )
    Jobs::RepoActivityPublish.new.execute(channel_id: channel.id)
    expect(page).to have_css(".repo-activity__pill", text: "1 new")
    expect(page).to have_css(".repo-activity__manage")
    expect(page).to have_css(".repo-activity__event", text: "Live push")
  end

  it "does not show repository management in a DM" do
    user.update!(admin: true)
    dm = Fabricate(:direct_message_channel, users: [user, Fabricate(:user)])
    visit("/chat/c/-/#{dm.id}")
    expect(page).to have_css(".c-navbar")
    expect(page).to have_no_css(".repo-activity__pill, .repo-activity__settings")
  end

  it "merges a read from another device and preserves newer unread events" do
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__pill", text: "1 new")
    MessageBus.publish(
      "/repo-activity/#{channel.id}",
      { last_seen_event_id: activity.id },
      user_ids: [user.id],
    )
    expect(page).to have_no_css(".repo-activity__pill", text: "1 new")
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "push",
      summary: {
        title: "Newer push",
      },
    )
    Jobs::RepoActivityPublish.new.execute(channel_id: channel.id)
    expect(page).to have_css(".repo-activity__pill", text: "1 new")
    MessageBus.publish(
      "/repo-activity/#{channel.id}",
      { last_seen_event_id: 0 },
      user_ids: [user.id],
    )
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__event--new", text: "Newer push")
    expect(page).to have_no_css(".repo-activity__event--new", text: "Push to main")
  end

  it "keeps repo rows compact, filters the channel stream and expands grouped pushes" do
    other = connection.dup
    other.repo_path = "acme/other"
    other.display_name = "other"
    other.public_id = SecureRandom.hex(20)
    other.save!
    other.events.create!(
      chat_channel_id: channel.id,
      kind: "issue_opened",
      summary: {
        title: "Other issue",
      },
    )
    DiscourseRepoActivity::ChannelRead.create!(
      user_id: user.id,
      chat_channel_id: channel.id,
      last_seen_event_id: activity.id,
    )
    2.times do |push|
      connection.events.create!(
        chat_channel_id: channel.id,
        kind: "push",
        actor_login: "alice",
        summary: {
          ref: "feature",
          commit_count: 2,
          commits:
            2.times.map do |i|
              {
                sha: "%040x" % (push * 2 + i + 1),
                message: "Mode regression #{push * 2 + i + 1}",
                url: "https://github.com/acme/sim-tools/commit/#{push * 2 + i + 1}",
              }
            end,
        },
      )
    end
    connection.refs.create!(ref_name: "pr/99", kind: "pr", pr_number: 99)
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__repo-row", count: 2)
    expect(page).to have_no_text("PR/MR #99")
    expect(page).to have_css(".repo-activity__group-header", text: "alice → feature", count: 1)
    expect(page).to have_css(".repo-activity__commits li", count: 3)
    find(".repo-activity__expand").click
    expect(page).to have_css(".repo-activity__commits li", count: 4)
    expect(page).to have_css(".repo-activity__last-visit", text: "Since you looked")
    find(".repo-activity__repo-row", text: "sim-tools").click
    expect(page).to have_css(".repo-activity__repo-row.is-selected", text: "sim-tools")
    expect(page).to have_no_css(".repo-activity__event", text: "Other issue")
    click_button("All repos")
    expect(page).to have_css(".repo-activity__event", text: "Other issue")
    expect(page).to have_no_css(".repo-activity__repo-row.is-selected")
  end

  it "loads earlier items without replacing the latest commit stream" do
    35.times do |i|
      connection.events.create!(
        chat_channel_id: channel.id,
        kind: "issue_opened",
        summary: {
          title: "Issue #{i}",
        },
      )
    end
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__event", text: "Issue 34")
    expect(page).to have_no_css(".repo-activity__event", text: /Issue 0$/)
    click_button("Load earlier")
    expect(page).to have_css(".repo-activity__event", text: "Issue 0")
    expect(page).to have_css(".repo-activity__event", text: "Issue 34")
  end

  it "uses a dot and count on narrow headers and contains the mobile sheet", mobile: true do
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__compact-label", visible: true)
    expect(page).to have_no_css(".repo-activity__full-label", visible: true)
    expect(
      page.evaluate_script(
        "document.querySelector('.repo-activity__pill').getBoundingClientRect().width",
      ),
    ).to be < 80
    find(".repo-activity__pill").click
    expect(page).to have_css(".fk-d-menu-modal .repo-activity__stream")
    width =
      page.evaluate_script(
        "document.querySelector('.repo-activity__popover').getBoundingClientRect().width",
      )
    expect(width).to be <= page.evaluate_script("window.innerWidth")
  end
end
