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

  it "qualifies duplicate short names in overview chips and the opened stream" do
    other =
      DiscourseRepoActivity::Connection.create!(
        chat_channel: @channel,
        created_by: admin,
        forge: "gitlab",
        host: "gitlab.example.org",
        repo_path: "research/repo-0",
      )
    other.events.create!(
      chat_channel_id: @channel.id,
      kind: "push",
      summary: {
        title: "GitLab push",
      },
    )
    DiscourseRepoActivity::Connection.where(
      chat_channel: @channel,
      repo_path: %w[acme/repo-2 acme/repo-3],
    ).destroy_all
    visit("#{@workspace.url}/overview")
    expect(page).to have_css(".repo-activity__chip", text: "acme/repo-0")
    expect(page).to have_css(".repo-activity__chip", text: "research/repo-0")
    find(".repo-activity__chip", text: "research/repo-0").click
    expect(page).to have_css(".repo-activity__repo-row", text: "research/repo-0")
    expect(page).to have_css(".repo-activity__repo-row", text: "acme/repo-0")
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
    expect(page).to have_css(".repo-activity__card-new", text: "5 new")
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
    expect(page).to have_css(".repo-activity__card-new", text: "1 new", exact_text: true)
  end

  it "shows paused failures as muted, with no red header and unchanged unread counts" do
    DiscourseRepoActivity::Ref.where(
      connection_id: DiscourseRepoActivity::Connection.where(chat_channel: @channel).select(:id),
    ).update_all(ci_state: "success")
    connection =
      DiscourseRepoActivity::Connection.find_by!(chat_channel: @channel, repo_path: "acme/repo-0")
    connection.refs.update_all(ci_state: "failed")
    connection.update!(enabled: false)
    visit("#{@workspace.url}/overview")
    expect(page).to have_css(".repo-activity__chip--paused", text: /repo-0\s*Paused/)
    expect(page).to have_no_css(".repo-activity__chip-failure")
    expect(page).to have_css(".repo-activity__card-new", text: "5 new")
    find(".repo-activity__chip--paused").click
    expect(page).to have_css(".repo-activity__repo-row--paused", text: "Paused")
    expect(page).to have_no_css(".repo-activity__pill--failed")
  end

  it "uses snapshot bus cursors and chunks 201 channels without replay or losing rows" do
    visit("/latest")
    sizes = []
    page.driver.with_playwright_page do |browser|
      pattern = %r{/repo-activity/overview\.json}
      browser.route(
        pattern,
        ->(route, request) do
          ids =
            URI
              .decode_www_form(URI(request.url).query)
              .select { |key, _| key == "channel_ids[]" }
              .map(&:last)
          sizes << ids.length
          route.fulfill(
            status: 200,
            contentType: "application/json",
            body: {
              channels:
                ids.to_h { |id| [id, { repos: [], new_count: 0, message_bus_last_id: 41 }] },
            }.to_json,
          )
        end,
      )
      page.execute_script(<<~JS)
        const service = Discourse.lookup('service:repo-activity-overview');
        const bus = service.messageBus;
        window.busCursors = [];
        const subscribe = bus.subscribe;
        bus.subscribe = function(channel, callback, cursor) {
          if (Number(channel.split('/').at(-1)) >= 100001) { window.busCursors.push(cursor); return; }
          return subscribe.call(this, channel, callback, cursor);
        };
        window.stopBatch = service.watch(() => Array.from({length: 201}, (_, i) => ({chat_channel_id: 100001 + i})));
      JS
      try_until_success do
        expect(
          page.evaluate_script(
            "Object.keys(Discourse.lookup('service:repo-activity-overview').channels).length",
          ),
        ).to eq(201)
      end
      expect(sizes.sort).to eq([1, 200])
      expect(page.evaluate_script("window.busCursors.length")).to eq(201)
      expect(page.evaluate_script("window.busCursors.every(cursor => cursor === 41)")).to eq(true)
      page.execute_script("window.stopBatch()")
    ensure
      browser.unroute(pattern)
    end
  end

  it "expires pending navigation and cancels it when another route wins" do
    visit("#{@workspace.url}/overview")
    expect(page).to have_css(".repo-activity__chip")
    page.execute_script(<<~JS)
      const nav = Discourse.lookup('service:repo-activity-navigation');
      nav.request(#{@channel.id});
      nav.expiresAt = Date.now() - 1;
    JS
    expect(
      page.evaluate_script(
        "Discourse.lookup('service:repo-activity-navigation').consume(#{@channel.id})",
      ),
    ).to eq(false)
    page.execute_script(
      "Discourse.lookup('service:repo-activity-navigation').request(#{@channel.id}); Discourse.lookup('service:router').transitionTo('/latest')",
    )
    try_until_success do
      expect(
        page.evaluate_script(
          "Discourse.lookup('service:repo-activity-navigation').channelId === null",
        ),
      ).to eq(true)
    end
    page.execute_script(
      "Discourse.lookup('service:router').transitionTo('/chat/c/#{@channel.slug}/#{@channel.id}')",
    )
    expect(page).to have_css(".repo-activity__pill")
    expect(page).to have_no_css(".repo-activity__popover")
    expect(
      DiscourseRepoActivity::ChannelRead.where(user_id: user.id, chat_channel_id: @channel.id),
    ).not_to exist
  end

  it "renders join-first chips as plain text below the description, without unread links" do
    visit("#{@workspace.url}/overview")
    expect(page).to have_css(".repo-activity__chip")
    page.execute_script(<<~JS)
      const route = Discourse.lookup('service:router').currentRouteName;
      const model = Discourse.lookup('controller:' + route).model;
      const channel = model.activeChannels.find(c => c.chat_channel_id === #{@channel.id});
      channel.joined = false; channel.can_open_topics = false; channel.can_join = true;
    JS
    expect(page).to have_css("span.repo-activity__chip", count: 5)
    expect(page).to have_no_css("a.repo-activity__chip, .repo-activity__card-new")
    expect(page).to have_css('.repo-activity__card[role="group"]')
    expect(page).to have_css('[aria-label="1 more repository"]')
    expect(
      page.evaluate_script(
        "(() => { const row = document.querySelector('.repo-activity__card'); return row.getBoundingClientRect().top > row.closest('.workspace-groups-overview__card').querySelector('.workspace-groups-overview__channel-description').getBoundingClientRect().bottom; })()",
      ),
    ).to eq(true)
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
