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
      repo_path: "acme/sim-tools"
    )
  end
  fab!(:activity) do
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "push",
      actor_login: "alice",
      summary: {
        title: "Push to main",
        sha: "a" * 40
      }
    )
  end

  before do
    chat_system_bootstrap
    SiteSetting.repo_activity_enabled = true
    SiteSetting.discourse_workspace_groups_enabled = false if defined?(
      DiscourseWorkspaceGroups
    )

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
    expect(page).to have_css(
      ".fk-d-menu-modal .repo-activity__event",
      text: "Push to main"
    )
    expect(page).to have_no_css(".repo-activity__pill", text: "1 new")
  end

  it "updates the pill live for a new quiet event" do
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__pill", text: "1 new")
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "push",
      summary: {
        title: "Second push"
      }
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
        title: "Live push"
      }
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
    expect(page).to have_no_css(
      ".repo-activity__pill, .repo-activity__settings"
    )
  end
  it "merges a read from another device and preserves newer unread events" do
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__pill", text: "1 new")
    MessageBus.publish(
      "/repo-activity/#{channel.id}",
      { last_seen_event_id: activity.id },
      user_ids: [user.id]
    )
    expect(page).to have_no_css(".repo-activity__pill", text: "1 new")
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "push",
      summary: {
        title: "Newer push"
      }
    )
    Jobs::RepoActivityPublish.new.execute(channel_id: channel.id)
    expect(page).to have_css(".repo-activity__pill", text: "1 new")
    MessageBus.publish(
      "/repo-activity/#{channel.id}",
      { last_seen_event_id: 0 },
      user_ids: [user.id]
    )
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__event--new", text: "Newer push")
    expect(page).to have_no_css(
      ".repo-activity__event--new",
      text: "Push to main"
    )
  end
end
