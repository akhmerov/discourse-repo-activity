# frozen_string_literal: true

class IndexRepoActivityMessages < ActiveRecord::Migration[7.2]
  def change
    add_index :repo_activity_events, :chat_message_id
    add_index :repo_activity_refs, :failure_message_id
  end
end
