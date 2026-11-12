# frozen_string_literal: true

class AddRepoActivityRecoveryToggle < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE repo_activity_connections
      SET enabled_events = enabled_events || '["recovery"]'::jsonb
      WHERE enabled_events @> '["failure"]'::jsonb AND NOT enabled_events @> '["recovery"]'::jsonb
    SQL
    change_column_default :repo_activity_connections,
                          :enabled_events,
                          %w[
                            push
                            ci
                            failure
                            recovery
                            release
                            tag
                            pr_opened
                            pr_merged
                            issue_opened
                          ]
  end

  def down
    execute "UPDATE repo_activity_connections SET enabled_events = enabled_events - 'recovery'"
    change_column_default :repo_activity_connections,
                          :enabled_events,
                          %w[
                            push
                            ci
                            failure
                            release
                            tag
                            pr_opened
                            pr_merged
                            issue_opened
                          ]
  end
end
