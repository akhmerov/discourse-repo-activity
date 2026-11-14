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

  it "qualifies colliding names, uses native PR/MR identifiers and hides a retained tag when its release arrives" do
    other =
      DiscourseRepoActivity::Connection.create!(
        chat_channel: channel,
        created_by: user,
        forge: "gitlab",
        host: "gitlab.example.org",
        repo_path: "research/sim-tools",
      )
    [connection, other].each do |repo|
      repo.events.create!(
        chat_channel_id: channel.id,
        kind: "pr_merged",
        summary: {
          title: "Improve mesh",
          number: 244,
          url: "#{repo.repository_url}/changes/244",
        },
      )
    end
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "tag",
      summary: {
        tag: "v1.0",
        title: "v1.0",
      },
    )
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__repo-row", text: "acme/sim-tools")
    expect(page).to have_css(".repo-activity__repo-row", text: "research/sim-tools")
    expect(page).to have_css(
      ".repo-activity__event",
      text: "acme/sim-tools · PR merged · #244 Improve mesh",
    )
    expect(page).to have_css(
      ".repo-activity__event",
      text: "research/sim-tools · MR merged · !244 Improve mesh",
    )
    expect(page).to have_css(".repo-activity__event", text: "Tag · v1.0")
    other.events.create!(
      chat_channel_id: channel.id,
      kind: "release",
      summary: {
        tag: "v1.0",
        title: "Other release",
      },
    )
    DiscourseRepoActivity::Snapshot.publish_now(channel)
    expect(page).to have_css(".repo-activity__event", text: "Other release")
    expect(page).to have_css(".repo-activity__event", text: "Tag · v1.0")
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "release",
      summary: {
        tag: "v1.0",
        title: "Version 1",
      },
    )
    DiscourseRepoActivity::Snapshot.publish_now(channel)
    expect(page).to have_css(".repo-activity__event", text: "Release · Version 1")
    expect(page).to have_no_css(".repo-activity__event", text: "Tag · v1.0")
  end

  it "uses just now below a minute, preserving minute, hour and day ages" do
    activity.update!(created_at: 20.seconds.ago)
    [
      [70.seconds.ago, "One minute"],
      [2.hours.ago, "Two hours"],
      [3.days.ago, "Three days"],
    ].each do |time, title|
      connection.events.create!(
        chat_channel_id: channel.id,
        kind: "issue_opened",
        created_at: time,
        summary: {
          title: title,
        },
      )
    end
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "push",
      created_at: 20.seconds.ago,
      summary: {
        title: "Recent push",
      },
    )
    connection.refs.create!(ref_name: "main", kind: "branch", updated_at: 20.seconds.ago)
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__full-label", text: "just now")
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__repo-state", text: "just now")
    expect(page).to have_css(".repo-activity__group-header time", text: "just now", count: 2)
    expect(page).to have_css(".repo-activity__event", text: "One minute 1m")
    expect(page).to have_css(".repo-activity__event", text: "Two hours 2h")
    expect(page).to have_css(".repo-activity__event", text: "Three days 3d")
    expect(page).to have_no_text(/\b0m\b/)
  end

  it "uses a compact icon and unread badge on a narrow desktop" do
    page.current_window.resize_to(390, 844)
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__phone-icon", visible: true)
    expect(page).to have_css(".repo-activity__badge", text: "1")
    expect(page).to have_css('.repo-activity__pill[aria-label*="1 new"]')
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__popover")
    expect(page).to have_no_css(".repo-activity__badge")
  end

  it "opens the popover and resets the new count persistently" do
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__pill", text: "sim-tools")
    expect(page).to have_no_css(".repo-activity__badge", visible: true)
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
    DiscourseRepoActivity::ChannelRead.create!(
      user_id: user.id,
      chat_channel_id: channel.id,
      last_seen_event_id: activity.id,
    )
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

  it "labels the count on narrow headers and contains the mobile sheet", mobile: true do
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__phone-icon", visible: true)
    expect(page).to have_no_css(".repo-activity__full-label", visible: true)
    expect(
      page.evaluate_script(
        "document.querySelector('.repo-activity__pill').getBoundingClientRect().width",
      ),
    ).to be < 110
    find(".repo-activity__pill").click
    expect(page).to have_css(".fk-d-menu-modal .repo-activity__stream")
    width =
      page.evaluate_script(
        "document.querySelector('.repo-activity__popover').getBoundingClientRect().width",
      )
    expect(width).to be <= page.evaluate_script("window.innerWidth")
  end

  it "places the divider only between new and seen items across visits" do
    connection.events.create!(chat_channel_id: channel.id, kind: "ci")
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__pill", text: "1 new")
    find(".repo-activity__pill").click
    expect(page).to have_no_css(".repo-activity__last-visit")
    expect(page).to have_css(".repo-activity__repo-row", text: "1 new")
    expect(page).to have_no_css(".repo-activity__pill", text: "1 new")
    expect(
      DiscourseRepoActivity::ChannelRead.find_by!(
        user_id: user.id,
        chat_channel_id: channel.id,
      ).last_seen_event_id,
    ).to eq(activity.id)
    find(".repo-activity__pill").click
    find(".repo-activity__pill").click
    expect(page).to have_no_css(".repo-activity__last-visit")
    expect(page).to have_no_css(".repo-activity__repo-row", text: "1 new")
    find(".repo-activity__pill").click
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "issue_opened",
      summary: {
        title: "Fresh issue",
      },
    )
    Jobs::RepoActivityPublish.new.execute(channel_id: channel.id)
    expect(page).to have_css(".repo-activity__pill", text: "1 new")
    find(".repo-activity__pill").click
    expect(page).to have_css(".repo-activity__event--new", text: "Fresh issue")
    expect(page).to have_css(".repo-activity__last-visit", count: 1)
    expect(page).to have_css(
      ".repo-activity__event--new + .repo-activity__last-visit + .repo-activity__event",
      text: "Push to main",
    )
  end

  it "keeps every loaded event after a live burst displaces the entire first page" do
    65.times do |index|
      connection.events.create!(
        chat_channel_id: channel.id,
        kind: "issue_opened",
        summary: {
          title: "Historical #{index}",
        },
      )
    end
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    find(".repo-activity__pill").click
    click_button("Load earlier")
    expect(page).to have_css(".repo-activity__event", text: "Historical 5")
    35.times do |index|
      connection.events.create!(
        chat_channel_id: channel.id,
        kind: "issue_opened",
        summary: {
          title: "Incoming #{index}",
        },
      )
    end
    Jobs::RepoActivityPublish.new.execute(channel_id: channel.id)
    expect(page).to have_css(".repo-activity__event", text: "Incoming 34")
    expect(page).to have_css(".repo-activity__event", text: /Incoming 0 just now$/)
    expect(page).to have_css(".repo-activity__event", text: "Historical 35")
    expect(page).to have_css(".repo-activity__event", text: "Historical 5")
    expect(page).to have_css(".repo-activity__event", count: 95)
    click_button("Load earlier")
    expect(page).to have_css(".repo-activity__event", text: "Push to main")
    expect(page).to have_css(".repo-activity__event", count: 101)
  end

  it "coalesces live refresh bursts and leaves background failures silent" do
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    expect(page).to have_css(".repo-activity__pill")
    page.execute_script(<<~JS)
      window.repoRequests = 0;
      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        if (String(url).includes('/repo-activity/channels/')) {
          window.repoRequests++;
        }
        return originalOpen.call(this, method, url, ...rest);
      };
    JS
    8.times { Jobs::RepoActivityPublish.new.execute(channel_id: channel.id) }
    connection.events.create!(
      chat_channel_id: channel.id,
      kind: "issue_opened",
      summary: {
        title: "One refresh",
      },
    )
    Jobs::RepoActivityPublish.new.execute(channel_id: channel.id)
    expect(page).to have_css(".repo-activity__pill", text: "2 new")
    expect(page.evaluate_script("window.repoRequests")).to be <= 2
    # Force the next background GET to receive a real missing-route response.
    page.execute_script(<<~JS)
      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        if (String(url).includes('/repo-activity/channels/')) {
          this.addEventListener('loadend', () => { window.repoBackgroundFailed = true; });
          url = '/repo-activity/not-found.json';
        }
        return originalOpen.call(this, method, url, ...rest);
      };
    JS
    Jobs::RepoActivityPublish.new.execute(channel_id: channel.id)
    try_until_success { expect(page.evaluate_script("window.repoBackgroundFailed")).to eq(true) }
    expect(page).to have_no_css(".dialog-container")
    expect(page).to have_css(".repo-activity__pill", text: "2 new")
  end
end
