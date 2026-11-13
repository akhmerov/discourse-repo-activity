# frozen_string_literal: true

RSpec.describe "Repository management screens" do
  fab!(:admin)
  fab!(:channel, :chat_channel)
  fab!(:connection) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: admin,
      forge: "github",
      host: "github.com",
      repo_path: "acme/existing",
    )
  end

  before do
    chat_system_bootstrap
    SiteSetting.repo_activity_enabled = true
    SiteSetting.discourse_workspace_groups_enabled = false
    channel.add(admin)
    sign_in(admin)
  end

  def open_manager
    visit("/chat/c/#{channel.slug}/#{channel.id}")
    find(".repo-activity__pill").click
    find(".repo-activity__manage").click
    expect(page).to have_css(".repo-manager__row")
  end

  def verified_ping(repo, events)
    body = JSON.generate(hook: { events: events })
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post(
      "/repo-activity/hooks/#{repo.public_id}",
      params: body,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "X-GitHub-Event" => "ping",
        "X-GitHub-Delivery" => SecureRandom.uuid,
        "X-Hub-Signature-256" => "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", repo.secret, body),
      },
    )
    expect(session.response.status).to eq(200)
  end

  it "parses repo addresses, guides setup, reveals explicitly and checks delivery live" do
    open_manager
    expect(page).to have_no_css(".repo-manager__secret")
    click_button("Add repository")
    {
      "github.com/Acme/new-project.git/" => "GitHub · repository acme/new-project",
      "https://gitlab.tudelft.nl/qt/sub/mesh-tools/-/tree/main" =>
        "GitLab at gitlab.tudelft.nl · project qt/sub/mesh-tools",
      "git@gitlab.tudelft.nl:qt/mesh-tools.git" =>
        "GitLab at gitlab.tudelft.nl · project qt/mesh-tools",
      "https://github.com/acme/new-project/tree/main" => "GitHub · repository acme/new-project",
    }.each do |address, preview|
      fill_in("Repository address", with: address)
      expect(page).to have_css(".repo-manager__preview", text: preview)
    end
    click_button("Continue")
    expect(page).to have_text("Content type: either option works")
    expect(page).to have_css('.repo-manager__steps [aria-current="step"]', text: "2 Webhook")
    expect(page).to have_no_text("— Webhook")
    expect(page).to have_css("a[href='https://github.com/acme/new-project/settings/hooks/new']")
    expect(page).to have_css(".repo-manager__secret[type=password]")
    click_button("Show")
    expect(page).to have_css(".repo-manager__secret[type=text]")
    click_button("Hide")
    expect(page).to have_css(".repo-manager__secret[type=password]")
    page.execute_script(<<~JS)
      window.secretRequests = 0;
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...args) {
        if (url.includes('/secret.json')) { window.secretRequests++; }
        return open.call(this, method, url, ...args);
      };
      const validate = (text) => {
        window.repoClipboardValid = text.includes('Secret: <secret — I’ll send it separately>') && !/[a-f0-9]{64}/.test(text) && text.includes('/repo-activity/hooks/') && text.includes('Required: Pushes and Workflow runs');
      };
      Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
        write: async (items) => { validate(await (await items[0].getType('text/plain')).text()); },
        writeText: async (text) => validate(text),
      }});
    JS
    click_button("Copy instructions for a repo admin")
    expect(page).to have_text("Copied to clipboard")
    expect(page.evaluate_script("window.repoClipboardValid")).to eq(true)
    expect(page.evaluate_script("window.secretRequests")).to eq(0)
    click_button("I’ve added it")
    expect(page).to have_text("Waiting for GitHub’s test delivery")
    repo = DiscourseRepoActivity::Connection.find_by!(repo_path: "acme/new-project")
    verified_ping(repo, %w[push])
    expect(page).to have_text("✓ Connected")
    expect(page).to have_text("Workflow runs are not enabled")
    click_button("Done")
    expect(page).to have_css(".repo-manager__row", text: "acme/new-project")
  end

  it "pauses, rotates with confirmation and removes" do
    connection_id = connection.id
    open_manager
    row = find(".repo-manager__row", text: "acme/existing")
    row.find(".d-toggle-switch__checkbox-slider").click
    expect(page).to have_text("Paused · deliveries are ignored")
    row.find(".repo-manager__menu-trigger").click
    click_button("New secret…")
    expect(page).to have_text("Create a new secret?")
    find(".dialog-footer .btn-primary").click
    expect(page).to have_text("This is a new secret")
    expect(page).to have_css(".repo-manager__secret[type=password]")
    click_button("I’ve added it")
    expect(page).to have_text(
      "This repository is paused. Turn it on in the repository list before testing.",
    )
    click_button("Back")
    click_button("Back")
    find(".repo-manager__menu-trigger").click
    click_button("Remove repository")
    expect(page).to have_text("Remove acme/existing from this channel?")
    find(".dialog-footer .btn-primary").click
    expect(page).to have_text("Connect a repository to follow its activity")
    expect(DiscourseRepoActivity::Connection.exists?(connection_id)).to eq(false)
  end
end
