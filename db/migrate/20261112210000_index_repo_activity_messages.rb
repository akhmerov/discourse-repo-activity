# frozen_string_literal: true

class IndexRepoActivityMessages < ActiveRecord::Migration[8.0]
  def change
    add_index :repo_activity_events, :chat_message_id
    add_index :repo_activity_refs, :failure_message_id
  end
end
