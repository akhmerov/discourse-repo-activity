# frozen_string_literal: true

class UseFixedRepoActivityEvents < ActiveRecord::Migration[8.0]
  def up
    remove_column :repo_activity_connections, :enabled_events
    add_column :repo_activity_connections, :received_event_types, :jsonb, null: false, default: {}
  end

  def down
    remove_column :repo_activity_connections, :received_event_types
    add_column :repo_activity_connections,
               :enabled_events,
               :jsonb,
               null: false,
               default: %w[push ci failure recovery release tag pr_opened pr_merged issue_opened]
  end
end
