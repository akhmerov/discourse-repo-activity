# frozen_string_literal: true

module DiscourseRepoActivity
  # Lock before native thread autosave touches the parent, using the announcer's
  # connection -> channel order. A human reply which wins is visible to recovery;
  # if recovery wins, the native service rejects the now-deleted parent.
  module IncidentReplies
    def call(context = {}, &actions)
      params = context[:params] || {}
      parent_id = params[:in_reply_to_id] || params["in_reply_to_id"]
      thread_id = params[:thread_id] || params["thread_id"]
      parent_id ||= Chat::Thread.find_by(id: thread_id)&.original_message_id if thread_id
      return super unless parent_id
      ref = Ref.find_by(failure_message_id: parent_id)
      return super unless ref
      return super if context[:guardian]&.user&.id == Bot.user.id
      connection = ref.connection
      connection.with_lock { connection.chat_channel.with_lock { super } }
    end
  end
end
