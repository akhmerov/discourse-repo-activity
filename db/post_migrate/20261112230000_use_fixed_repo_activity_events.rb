# frozen_string_literal: true

class UseFixedRepoActivityEvents < ActiveRecord::Migration[8.0]
  def up
    remove_column :repo_activity_connections, :enabled_events
  end

  def down
    add_column :repo_activity_connections,
               :enabled_events,
               :jsonb,
               null: false,
               default: %w[push ci failure recovery release tag pr_opened pr_merged issue_opened]
  end
end
