# frozen_string_literal: true

module DiscourseRepoActivity
  class Announcer
    def initialize(connection)
      @connection = connection
    end

    def announce
      c = @connection
      c.with_lock do
        c.chat_channel.with_lock do
          unless c.active_channel?
            c.discard_pending!
            return
          end
          pending =
            c.events.where(loud: true, chat_message_id: nil).order(:id).to_a
          pending.each do |event|
            if event.kind == "failure" &&
                 c.refs.exists?(
                   ref_name: event.summary["ref"],
                   ci_state: "success"
                 )
              event.update!(loud: false)
            end
          end
          pending.select!(&:loud)
          return if pending.empty?
          bot = Bot.user
          # Native bot membership does not widen the channel audience.
          c.chat_channel.add(bot)
          refs = c.refs.to_a
          edits =
            pending
              .select { |e| %w[failure recovery].include?(e.kind) }
              .group_by { |e| e.summary["ref"] }
          edits.each do |name, events|
            ref = refs.find { |r| r.ref_name == name }
            next unless ref
            message =
              Chat::Message.find_by(
                id: ref.failure_message_id,
                chat_channel_id: c.chat_channel_id,
                user_id: bot.id
              )
            unless message
              if events.any? { |e| e.kind == "recovery" }
                ref.update!(failure_message_id: nil, failing_since: nil)
                # A same-window failure can still produce its initial alert.
                unless events.any? { |e| e.kind == "failure" }
                  events.each { |e| e.update!(loud: false) }
                end
              end
              next
            end
            events.each { |e| e.update!(chat_message_id: message.id) }
            update(message.id, render_message(message, ref, events))
            if ref.ci_state == "success" &&
                 @connection.enabled_events.include?("recovery")
              create(
                "#{escape(c.display_name)} fixed in #{escape(ref.head_sha.to_s[0, 8])}",
                reply_to: message.id
              )
              ref.update!(failure_message_id: nil, failing_since: nil)
            end
          end
          pending = pending.select { |e| e.reload.chat_message_id.nil? }
          # A closed/deleted ref cannot contribute an actionable failure line.
          pending
            .select { |event| %w[failure recovery].include?(event.kind) }
            .each do |event|
              unless c.refs.exists?(ref_name: event.summary["ref"])
                event.update!(loud: false)
              end
            end
          pending.select!(&:loud)
          return if pending.empty?
          text = render_events(pending, mention: true)
          return if text.blank?
          message = create(text)
          pending.each { |e| e.update!(chat_message_id: message.id) }
          pending
            .select { |event| event.kind == "failure" }
            .map { |event| event.summary["ref"] }
            .uniq
            .each do |name|
              ref = c.refs.find_by(ref_name: name)
              next unless ref
              if ref.ci_state == "success" &&
                   @connection.enabled_events.include?("recovery")
                create(
                  "#{escape(c.display_name)} fixed in #{escape(ref.head_sha.to_s[0, 8])}",
                  reply_to: message.id
                )
                ref.update!(failure_message_id: nil, failing_since: nil)
              elsif ref.ci_state == "success"
                ref.update!(failure_message_id: nil, failing_since: nil)
              else
                ref.update!(failure_message_id: message.id)
              end
            end
        end
      end
    end

    private

    def create(text, reply_to: nil)
      result =
        Chat::CreateMessage.call(
          guardian: BotGuardian.new(@connection),
          params: {
            chat_channel_id: @connection.chat_channel_id,
            message: text,
            in_reply_to_id: reply_to
          },
          options: {
            force_thread: reply_to.present?
          }
        )
      if result.failure?
        raise "Repository activity message could not be created"
      end
      result[:message_instance]
    end

    def update(id, text)
      result =
        Chat::UpdateMessage.call(
          guardian: BotGuardian.new(@connection),
          params: {
            channel_id: @connection.chat_channel_id,
            message_id: id,
            message: text
          }
        )
      if result.failure?
        raise "Repository activity message could not be updated"
      end
    end

    def render_message(message, ref, events)
      # Preserve other coalesced announcements even after event retention prunes
      # their source rows. Only this bot's existing failure line changes.
      prefix = "CI failing on #{escape(ref.ref_name)} ("
      replacement =
        (
          if ref.ci_state == "success" &&
               @connection.enabled_events.include?("recovery")
            "fixed in #{escape(ref.head_sha.to_s[0, 8])}"
          else
            sha =
              events
                .reverse
                .find { |e| e.kind == "failure" }
                &.summary
                &.dig("sha")
                .presence
            return message.message if sha.blank?
            "#{prefix}#{escape(sha.to_s[0, 8])})"
          end
        )
      message
        .message
        .lines
        .map do |line|
          line.sub(/\A(?:@\S+ )?#{Regexp.escape(prefix)}[^\n]+/, replacement)
        end
        .join
    end

    def render_events(events, mention:)
      releases =
        events.select { |e| e.kind == "release" }.map { |e| e.summary["tag"] }
      lines =
        events.reject do |e|
          e.kind == "tag" && releases.include?(e.summary["tag"])
        end
      failures =
        lines
          .select { |e| %w[failure recovery].include?(e.kind) }
          .group_by { |e| e.summary["ref"] }
      lines.reject! { |e| %w[failure recovery].include?(e.kind) }
      output =
        lines.map do |e|
          "#{escape(e.kind.tr("_", " "))}: #{link(e.summary["title"], e.summary["url"])}"
        end
      alerts = []
      failures.each do |name, ref_events|
        ref = @connection.refs.find_by(ref_name: name)
        next unless ref
        status =
          (
            if ref.ci_state == "success" &&
                 @connection.enabled_events.include?("recovery")
              "fixed in #{escape(ref.head_sha.to_s[0, 8])}"
            else
              "CI failing on #{escape(name)} (#{escape(ref_events.reverse.find { |e| e.kind == "failure" }&.summary&.dig("sha").to_s[0, 8])})"
            end
          )
        prefix = mention && ref.ci_state == "failed" ? pusher_mention(ref) : nil
        alerts << [prefix, status].compact.join(" ")
      end
      fit_message("**#{escape(@connection.display_name)}**", output, alerts)
    end

    def fit_message(header, lines, alerts)
      limit = SiteSetting.chat_maximum_message_length
      text = [header, *lines, *alerts].join("\n")
      return text if text.length <= limit
      kept = []
      suffix = "#{lines.length} more events in the repository activity popover."
      lines.each do |line|
        if [header, *kept, line, *alerts, suffix].join("\n").length > limit
          break
        end
        kept << line
      end
      suffix =
        "#{lines.length - kept.length} more events in the repository activity popover."
      [header, *kept, *alerts, suffix].join("\n").truncate(limit)
    end

    def pusher_mention(ref)
      user = User.find_by(username_lower: ref.pushed_by_login.to_s.downcase)
      unless user &&
               DiscourseRepoActivity.can_view?(
                 @connection.chat_channel,
                 user
               ) &&
               @connection.chat_channel.user_chat_channel_memberships.exists?(
                 user_id: user.id
               )
        return
      end
      "@#{user.username}"
    end

    def link(title, url)
      if url.present?
        "[#{title_text(title)}](#{url.gsub(/[()\\\s]/) { |s| ERB::Util.url_encode(s) }})"
      else
        title_text(title)
      end
    end

    def title_text(value)
      # Code spans disable URL/hashtag/mention and Markdown interpretation.
      # Use a delimiter longer than any backtick run in the untrusted text.
      title = value.to_s
      delimiter = "`" * ((title.scan(/`+/).map(&:length).max || 0) + 1)
      "#{delimiter} #{title} #{delimiter}"
    end

    def escape(value)
      title_text(value)
    end
  end
end
