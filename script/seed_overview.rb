# frozen_string_literal: true

unless Rails.env.development? &&
         ActiveRecord::Base.connection_db_config.database == "repo_activity_fleet"
  abort "Disposable overview instance required"
end

owner = User.find_by!(username: "sim_mira_vale")
workspace = Category.find_by!(slug: "aurora-research-lab")
coordination =
  workspace.subcategories.find_by(name: "Coordination") ||
    DiscourseWorkspaceGroups::CreateChannel.new(
      workspace: workspace,
      user: owner,
      name: "Coordination",
      description: "Meetings, visitors and shared lab plans",
      visibility: "public",
    ).call
coordination_chat = Chat::Channel.find_by!(chatable: coordination)
DiscourseRepoActivity::Connection
  .joins(:chat_channel)
  .where(chat_channels: { name: "Planning" })
  .find_each { |connection| connection.update!(enabled: false) }
Tag.find_or_create_by!(name: "244")
read_profiles = {
  "sim_theo_linden" => {
    "Engineering" => 37,
    "Analysis" => 4,
    "Instruments" => 0,
    "Releases" => 2,
    "Operations" => 0,
    "Documentation" => 1,
    "Archive" => 0,
    "Planning" => 0,
    "Repository setup" => 0,
    "Coordination" => 0,
  },
  "sim_mira_vale" => {
    "Engineering" => 9,
    "Analysis" => 0,
    "Instruments" => 3,
    "Releases" => 0,
    "Operations" => 1,
    "Documentation" => 0,
    "Archive" => 0,
    "Planning" => 0,
    "Repository setup" => 0,
    "Coordination" => 0,
  },
}
read_profiles.each do |name, targets|
  user = User.find_by!(username: name)
  [Chat::Channel.find(11), coordination_chat].each do |channel|
    channel.chatable.workspace_group.add(user)
    channel.add(user)
  end
  targets.each do |channel_name, unread|
    channel =
      Chat::Channel.joins(
        "INNER JOIN categories ON categories.id = chat_channels.chatable_id AND chat_channels.chatable_type = 'Category'",
      ).find_by!(name: channel_name, categories: { parent_category_id: workspace.id })
    events =
      DiscourseRepoActivity::Event.visible.where(chat_channel_id: channel.id).order(id: :desc)
    cursor = events.offset(unread).pick(:id) || 0
    DiscourseRepoActivity::ChannelRead.find_or_initialize_by(
      user_id: user.id,
      chat_channel_id: channel.id,
    ).update!(last_seen_event_id: cursor)
  end
end
Stylesheet::Manager.recalculate_fs_asset_cachebuster!
puts "Varied member/owner read cursors ready; Planning paused; Coordination has no repositories; tag 244 exists"
