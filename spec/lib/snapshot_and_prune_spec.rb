# frozen_string_literal: true

RSpec.describe DiscourseRepoActivity::Snapshot do
  fab!(:admin)
  fab!(:member, :user)
  fab!(:outsider, :user)
  fab!(:group)
  fab!(:channel) { Fabricate(:private_category_channel, group: group) }
  fab!(:connection) do
    DiscourseRepoActivity::Connection.create!(
      chat_channel: channel,
      created_by: admin,
      forge: "github",
      host: "github.com",
      repo_path: "acme/sim-tools",
      default_branch: "main"
    )
  end

  before do
    SiteSetting.chat_enabled = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    group.add(member)
    channel.add(member)
  end

  it "publishes only to the current private channel audience" do
    messages =
      MessageBus.track_publish("/repo-activity/#{channel.id}") do
        DiscourseRepoActivity::Snapshot.publish(channel)
      end
    ids = messages.flat_map(&:user_ids)
    expect(ids).to include(member.id, admin.id)
    expect(ids).not_to include(outsider.id)
    expect(messages.to_json).not_to include(
      connection.secret,
      connection.public_id
    )
    group.remove(member)
    messages =
      MessageBus.track_publish("/repo-activity/#{channel.id}") do
        DiscourseRepoActivity::Snapshot.publish(channel)
      end
    expect(messages.flat_map(&:user_ids)).not_to include(member.id)
  end

  it "keeps 50 events and prunes only idle non-default branches" do
    55.times do
      connection.events.create!(chat_channel_id: channel.id, kind: "push")
    end
    connection.refs.create!(ref_name: "main", updated_at: 20.days.ago)
    connection.refs.create!(ref_name: "old", updated_at: 20.days.ago)
    connection.refs.create!(ref_name: "recent", updated_at: 1.day.ago)
    connection.refs.create!(
      ref_name: "pr/3",
      kind: "pr",
      updated_at: 20.days.ago
    )
    newest = connection.events.maximum(:id)
    Jobs::RepoActivityPrune.new.execute({})
    expect(connection.events.count).to eq(50)
    expect(DiscourseRepoActivity::Event.pushes_today(connection.id)).to eq(55)
    expect(connection.events.maximum(:id)).to eq(newest)
    expect(connection.refs.pluck(:ref_name)).to contain_exactly(
      "main",
      "recent",
      "pr/3"
    )
  end
end
