# frozen_string_literal: true

unless Rails.env.development? &&
         ActiveRecord::Base.connection_db_config.database == "repo_activity_fleet"
  abort "Disposable overview instance required"
end

DiscourseRepoActivity::Connection
  .joins(:chat_channel)
  .where(chat_channels: { name: "Planning" })
  .find_each { |connection| connection.update!(enabled: false) }
%w[sim_theo_linden sim_mira_vale].each do |name|
  user = User.find_by!(username: name)
  setup = Chat::Channel.find(11)
  setup.chatable.workspace_group.add(user)
  setup.add(user)
  [3, 4].each do |id|
    events =
      DiscourseRepoActivity::Event
        .visible
        .where(chat_channel_id: id)
        .order(id: :desc)
        .limit(11)
        .pluck(:id)
    DiscourseRepoActivity::ChannelRead.find_or_initialize_by(
      user_id: user.id,
      chat_channel_id: id,
    ).update!(last_seen_event_id: events.last || 0)
  end
end
Stylesheet::Manager.recalculate_fs_asset_cachebuster!
puts "Engineering/Analysis unread fixtures ready; Planning has no active repositories"
