# frozen_string_literal: true

RSpec.describe "Workspace repository overview" do
  fab!(:admin)
  fab!(:user)
  fab!(:category)
  before do
    skip "Requires workspace-groups" unless defined?(DiscourseWorkspaceGroups)
    chat_system_bootstrap(user)
    SiteSetting.repo_activity_enabled = true
    SiteSetting.discourse_workspace_groups_enabled = true
    SiteSetting.navigation_menu = "sidebar"
    @workspace = DiscourseWorkspaceGroups::EnsureWorkspace.new(category: category, user: admin).call
    @workspace.workspace_group.add(user)
    @category =
      DiscourseWorkspaceGroups::CreateChannel.new(
        workspace: @workspace,
        user: admin,
        name: "Repository setup",
        description: "Research",
        visibility: "public",
      ).call
    @channel = Chat::Channel.find_by!(chatable: @category)
    @category.workspace_group.add(user)
    @channel.add(user)
    5.times do |index|
      c =
        DiscourseRepoActivity::Connection.create!(
          chat_channel: @channel,
          created_by: admin,
          forge: "github",
          host: "github.com",
          repo_path: "acme/repo-#{index}",
          default_branch: "main",
        )
      c.refs.create!(
        kind: "branch",
        ref_name: "main",
        ci_state: index == 4 ? "failed" : "success",
        head_sha: "a" * 40,
      )
      c.events.create!(
        chat_channel_id: @channel.id,
        kind: "push",
        summary: {
          title: "Research push #{index}",
        },
      )
    end
    sign_in(user)
  end

  it "keeps workspace cards usable when repository activity is disabled" do
    SiteSetting.repo_activity_enabled = false
    visit("#{@workspace.url}/overview")
    expect(page).to have_css(".workspace-groups-overview__card", text: "Repository setup")
    expect(page).to have_no_css(".repo-activity__card")
  end

  it "caps chips, opens activity directly, and updates counts on return and live delivery" do
    visit("#{@workspace.url}/overview")
    expect(page).to have_css(".repo-activity__chip", count: 5)
    expect(page).to have_css(".repo-activity__chip", text: "+1")
    expect(page).to have_css(".repo-activity__chip-failure", text: "main failing")
    expect(page).to have_css(".repo-activity__card-new", text: "5 new commits")
    find(".repo-activity__chip", text: "repo-0").click
    expect(page).to have_css(".repo-activity__popover")
    expect(page).to have_no_css(".repo-activity__pill", text: "5 new")
    visit("#{@workspace.url}/overview")
    expect(page).to have_css(".repo-activity__chip", text: "repo-0")
    expect(page).to have_no_css(".repo-activity__card-new")
    connection =
      DiscourseRepoActivity::Connection.find_by!(chat_channel: @channel, repo_path: "acme/repo-0")
    connection.events.create!(
      chat_channel_id: @channel.id,
      kind: "push",
      summary: {
        title: "Live push",
      },
    )
    DiscourseRepoActivity::Snapshot.publish_now(@channel)
    expect(page).to have_css(".repo-activity__card-new", text: "1 new commit", exact_text: true)
  end

  it "fits the full Repository setup title at 390px in mobile view", mobile: true do
    page.current_window.resize_to(390, 844)
    visit("#{@workspace.url}/overview")
    find(".repo-activity__chip", text: "repo-0").click
    expect(page).to have_css(".repo-activity__popover")
    page.send_keys(:escape)
    expect(page).to have_no_css(".repo-activity__popover")
    expect(page).to have_css(".repo-activity__phone-icon", visible: true)
    title =
      page.evaluate_script(
        "(() => { const el = document.querySelector('.c-navbar__channel-title .chat-channel-name__label'); return {text: el.textContent, width: el.clientWidth, scroll: el.scrollWidth}; })()",
      )
    expect(title["text"]).to include("Repository setup")
    expect(title["scroll"]).to be <= title["width"]
  end
end
