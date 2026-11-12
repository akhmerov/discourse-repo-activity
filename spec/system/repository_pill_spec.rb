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
    expect(page).to have_css(".repo-activity__pill", text: "2 new")
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__event--new", text: "Second push")
  end
end
