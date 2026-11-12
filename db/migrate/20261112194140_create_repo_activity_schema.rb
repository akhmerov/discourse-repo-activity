# frozen_string_literal: true

class CreateRepoActivitySchema < ActiveRecord::Migration[8.0]
  def change
    create_table :repo_activity_connections do |t|
      t.bigint :chat_channel_id, null: false
      t.integer :created_by_id, null: false
      t.string :forge, null: false
      t.string :host, null: false
      t.string :repo_path, null: false
      t.string :display_name, null: false
      t.string :default_branch
      t.string :public_id, null: false
      t.integer :secret_version, null: false, default: 1
      t.jsonb :enabled_events,
              null: false,
              default: %w[
                push
                ci
                failure
                release
                tag
                pr_opened
                pr_merged
                issue_opened
              ]
      t.boolean :enabled, null: false, default: true
      t.datetime :last_delivery_at
      t.string :last_delivery_error
      t.timestamps
    end
    add_index :repo_activity_connections, :public_id, unique: true
    add_index :repo_activity_connections,
              %i[chat_channel_id host repo_path],
              unique: true,
              name: "repo_activity_unique_connection"
    add_foreign_key :repo_activity_connections,
                    :chat_channels,
                    on_delete: :cascade

    create_table :repo_activity_refs do |t|
      t.bigint :connection_id, null: false
      t.string :ref_name, null: false
      t.string :kind, null: false, default: "branch"
      t.integer :pr_number
      t.string :head_sha
      t.string :pushed_by_login
      t.string :ci_state, null: false, default: "none"
      t.jsonb :ci_runs, null: false, default: {}
      t.bigint :failure_message_id
      t.datetime :failing_since
      t.datetime :updated_at, null: false
    end
    add_index :repo_activity_refs, %i[connection_id ref_name], unique: true
    add_foreign_key :repo_activity_refs,
                    :repo_activity_connections,
                    column: :connection_id,
                    on_delete: :cascade

    create_table :repo_activity_events do |t|
      t.bigint :connection_id, null: false
      t.bigint :chat_channel_id, null: false
      t.string :kind, null: false
      t.string :actor_login
      t.jsonb :summary, null: false, default: {}
      t.boolean :loud, null: false, default: false
      t.bigint :chat_message_id
      t.datetime :created_at, null: false
    end
    add_index :repo_activity_events,
              %i[chat_channel_id id],
              order: {
                id: :desc
              }
    add_index :repo_activity_events, %i[connection_id id], order: { id: :desc }
    add_foreign_key :repo_activity_events,
                    :repo_activity_connections,
                    column: :connection_id,
                    on_delete: :cascade

    create_table :repo_activity_channel_reads,
                 primary_key: %i[user_id chat_channel_id] do |t|
      t.integer :user_id, null: false
      t.bigint :chat_channel_id, null: false
      t.bigint :last_seen_event_id, null: false, default: 0
    end
    add_foreign_key :repo_activity_channel_reads, :users, on_delete: :cascade
    add_foreign_key :repo_activity_channel_reads,
                    :chat_channels,
                    on_delete: :cascade
  end
end
