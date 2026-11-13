# frozen_string_literal: true

require_relative "../../db/migrate/20261112225000_add_received_repo_activity_events"

RSpec.describe DiscourseRepoActivity::Connection do
  it "creates and serializes connections after regular migrations, before the legacy column is dropped" do
    db = ActiveRecord::Base.connection
    db.add_column :repo_activity_connections, :enabled_events, :jsonb, default: ["push"]
    db.remove_column :repo_activity_connections, :received_event_types
    AddReceivedRepoActivityEvents.new.migrate(:up)
    DiscourseRepoActivity::Connection.reset_column_information
    expect(DiscourseRepoActivity::Connection.ignored_columns).to include("enabled_events")
    expect(DiscourseRepoActivity::Connection.column_names).not_to include("enabled_events")
    connection =
      DiscourseRepoActivity::Connection.create!(
        chat_channel: Fabricate(:chat_channel),
        created_by: Fabricate(:admin),
        forge: "github",
        host: "github.com",
        repo_path: "acme/rolling-deploy",
      )
    expect(connection.received_event_types).to eq({})
    DiscourseRepoActivity::DeliveryStatus.record(connection, "receiving", event_type: "push")
    expect(connection.reload.received_event_types.keys).to eq(["push"])
    expect(connection.management_json["delivery_status"]).to eq("receiving")
  ensure
    if db.column_exists?(:repo_activity_connections, :enabled_events)
      db.remove_column :repo_activity_connections, :enabled_events
    end
    unless db.column_exists?(:repo_activity_connections, :received_event_types)
      AddReceivedRepoActivityEvents.new.migrate(:up)
    end
    DiscourseRepoActivity::Connection.reset_column_information
  end
end
