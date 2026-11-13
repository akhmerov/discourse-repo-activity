# frozen_string_literal: true

class AddRepoActivityDeliveryStatus < ActiveRecord::Migration[8.0]
  def change
    add_column :repo_activity_connections,
               :delivery_status,
               :string,
               null: false,
               default: "waiting"
    add_column :repo_activity_connections, :last_delivery_error_at, :datetime
    add_column :repo_activity_connections, :status_written_at, :datetime
    add_column :repo_activity_connections, :rejected_deliveries, :integer, null: false, default: 0
    add_column :repo_activity_connections, :missing_hook_events, :jsonb, null: false, default: []
    reversible { |direction| direction.up { execute <<~SQL } }
          UPDATE repo_activity_connections
          SET delivery_status = CASE
            WHEN last_delivery_error = 'Invalid payload' THEN 'invalid_payload'
            WHEN last_delivery_error IS NOT NULL THEN 'wrong_secret'
            WHEN last_delivery_at IS NOT NULL THEN 'receiving'
            ELSE 'waiting' END,
            last_delivery_error = CASE
              WHEN last_delivery_error = 'Invalid payload' THEN 'invalid_payload'
              WHEN last_delivery_error IS NOT NULL THEN 'wrong_secret'
              ELSE NULL END
        SQL
  end
end
