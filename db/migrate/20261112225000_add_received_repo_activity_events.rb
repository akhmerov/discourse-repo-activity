# frozen_string_literal: true

class AddReceivedRepoActivityEvents < ActiveRecord::Migration[8.0]
  def up
    # Older local installs already ran the original post-deployment migration.
    unless column_exists?(:repo_activity_connections, :received_event_types)
      add_column :repo_activity_connections, :received_event_types, :jsonb, null: false, default: {}
    end
  end

  def down
    remove_column :repo_activity_connections, :received_event_types
  end
end
