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
          pending = c.events.where(loud: true, chat_message_id: nil).order(:id).to_a
          pending.each do |event|
            if event.kind == "failure" &&
                 c.refs.exists?(ref_name: event.summary["ref"], ci_state: "success")
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
                user_id: bot.id,
              )
            unless message
              if events.any? { |e| e.kind == "recovery" }
                # A later failure in this window still needs its incident marker
                # so the next successful build can edit and recover the alert.
                ref.update!(
                  failure_message_id: nil,
                  failing_since: ref.ci_state == "success" ? nil : ref.failing_since,
                )
                # A same-window failure can still produce its initial alert.
                unless events.any? { |e| e.kind == "failure" }
                  events.each { |e| e.update!(loud: false) }
                end
              end
              next
            end
            events.each { |e| e.update!(chat_message_id: message.id) }
            if ref.ci_state == "success"
              # Reply insertion shares the channel lock (see plugin.rb).
              human_reply =
                Chat::Message
                  .where.not(user_id: bot.id)
                  .where(
                    "in_reply_to_id = ? OR thread_id IN (SELECT id FROM chat_threads WHERE original_message_id = ?)",
                    message.id,
                    message.id,
                  )
                  .exists?
              unless human_reply
                # CI alerts are separate from durable PR/issue/release messages.
                result =
                  Chat::TrashMessage.call(
                    guardian: BotGuardian.new(c),
                    params: {
                      channel_id: c.chat_channel_id,
                      message_id: message.id,
                    },
                  )
                if result.success?
                  ref.update!(failure_message_id: nil, failing_since: nil)
                  next
                end
                # A native trash refusal must not strand this connection's queue.
              end
            end
            update(message.id, render_message(message, ref, events))
            if ref.ci_state == "success"
              create(
                "#{escape(c.display_name)} fixed in #{escape(ref.head_sha.to_s[0, 8])}",
                reply_to: message.id,
              )
              ref.update!(failure_message_id: nil, failing_since: nil)
            end
          end
          pending = pending.select { |e| e.reload.chat_message_id.nil? }
          # A closed/deleted ref cannot contribute an actionable failure line.
          pending
            .select { |event| %w[failure recovery].include?(event.kind) }
            .each do |event|
              event.update!(loud: false) unless c.refs.exists?(ref_name: event.summary["ref"])
            end
          pending.select!(&:loud)
          return if pending.empty?
          # Keep disposable incident alerts separate from durable announcements.
          durable, incidents = pending.partition { |e| !%w[failure recovery].include?(e.kind) }
          if durable.any? && incidents.any?
            durable_message = create(render_events(durable, mention: false))
            durable.each { |e| e.update!(chat_message_id: durable_message.id) }
            pending = incidents
          end
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
              if ref.ci_state == "success"
                create(
                  "#{escape(c.display_name)} fixed in #{escape(ref.head_sha.to_s[0, 8])}",
                  reply_to: message.id,
                )
                ref.update!(failure_message_id: nil, failing_since: nil)
              else
                ref.update!(failure_message_id: message.id)
              end
            end
        end
      end
    end

    # A reply may have resolved the parent before recovery deleted it, then
    # waited on the channel lock. Preserve that conversation after insertion.
    def self.preserve_reply(message)
      parent_id = message.in_reply_to_id || message.thread&.original_message_id
      return unless parent_id
      event = Event.where(chat_message_id: parent_id, kind: "recovery").order(id: :desc).first
      return unless event
      return if message.user_id == Bot.user.id
      c = event.connection
      c.with_lock do
        c.chat_channel.with_lock do
          parent = Chat::Message.with_deleted.find_by(id: parent_id, user_id: Bot.user.id)
          return unless parent&.trashed? && parent.deleted_by_id == Bot.user.id
          result =
            Chat::RestoreMessage.call(
              guardian: BotGuardian.new(c),
              params: {
                channel_id: c.chat_channel_id,
                message_id: parent.id,
              },
            )
          raise "Repository activity alert could not be restored" if result.failure?
          announcer = new(c)
          fixed = "fixed in #{announcer.send(:escape, event.summary["sha"].to_s[0, 8])}"
          announcer.send(
            :update,
            parent.id,
            "**#{announcer.send(:escape, c.display_name)}**\n#{fixed}",
          )
          announcer.send(
            :create,
            "#{announcer.send(:escape, c.display_name)} #{fixed}",
            reply_to: parent.id,
          )
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
            in_reply_to_id: reply_to,
          },
          options: {
            force_thread: reply_to.present?,
          },
        )
      raise "Repository activity message could not be created" if result.failure?
      result[:message_instance]
    end

    def update(id, text)
      result =
        Chat::UpdateMessage.call(
          guardian: BotGuardian.new(@connection),
          params: {
            channel_id: @connection.chat_channel_id,
            message_id: id,
            message: text,
          },
        )
      raise "Repository activity message could not be updated" if result.failure?
    end

    def render_message(message, ref, events)
      # Preserve other coalesced announcements even after event retention prunes
      # their source rows. Only this bot's existing failure line changes.
      prefix = "CI failing on #{escape(ref.ref_name)} ("
      replacement =
        (
          if ref.ci_state == "success"
            "fixed in #{escape(ref.head_sha.to_s[0, 8])}"
          else
            sha = events.reverse.find { |e| e.kind == "failure" }&.summary&.dig("sha").presence
            return message.message if sha.blank?
            "#{prefix}#{escape(sha.to_s[0, 8])})"
          end
        )
      message
        .message
        .lines
        .map { |line| line.sub(/\A(?:@\S+ )?#{Regexp.escape(prefix)}[^\n]+/, replacement) }
        .join
    end

    def render_events(events, mention:)
      releases = events.select { |e| e.kind == "release" }.map { |e| e.summary["tag"] }
      lines = events.reject { |e| e.kind == "tag" && releases.include?(e.summary["tag"]) }
      failures =
        lines.select { |e| %w[failure recovery].include?(e.kind) }.group_by { |e| e.summary["ref"] }
      lines.reject! { |e| %w[failure recovery].include?(e.kind) }
      output =
        lines.map do |e|
          label = {
            "pr_opened" => "PR/MR opened",
            "pr_merged" => "PR/MR merged",
            "issue_opened" => "Issue opened",
            "release" => "Release",
            "tag" => "Tag",
          }.fetch(e.kind, e.kind.tr("_", " "))
          label = label.sub("PR/MR", @connection.forge == "gitlab" ? "MR" : "PR")
          identifier = nil
          if %w[pr_opened pr_merged issue_opened].include?(e.kind) &&
               e.summary["number"].to_s.match?(/\A[1-9]\d{0,9}\z/)
            sigil =
              @connection.forge == "gitlab" && %w[pr_opened pr_merged].include?(e.kind) ? "!" : "#"
            identifier = "#{sigil}#{e.summary["number"].to_i}"
          end
          "#{label} by #{escape(e.actor_login)}: #{link(e.summary["title"], e.summary["url"], identifier: identifier)}"
        end
      # Cap bursts by kind, preserving one short line for each retained event.
      output =
        lines
          .group_by(&:kind)
          .flat_map do |kind, batch|
            rendered = batch.first(3).map { |event| output[lines.index(event)] }
            if batch.length > 3
              rendered << "&#43; #{batch.length - 3} more #{{ "pr_opened" => "PRs/MRs opened", "pr_merged" => "PRs/MRs merged", "issue_opened" => "issues opened" }.fetch(kind, kind.tr("_", " "))}"
            end
            rendered
          end
      alerts = []
      failures.each do |name, ref_events|
        ref = @connection.refs.find_by(ref_name: name)
        next unless ref
        status =
          (
            if ref.ci_state == "success"
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
      text = [header, *lines, *alerts].join("\n\n")
      return text if text.length <= limit
      kept = []
      suffix = "#{lines.length} more events in the repository activity popover."
      lines.each do |line|
        next if [header, *kept, line, *alerts, suffix].join("\n\n").length > limit
        kept << line
      end
      suffix = "#{lines.length - kept.length} more events in the repository activity popover."
      [header, *kept, *alerts, suffix].join("\n\n").truncate(limit)
    end

    def pusher_mention(ref)
      user = User.find_by(username_lower: ref.pushed_by_login.to_s.downcase)
      unless user && DiscourseRepoActivity.can_view?(@connection.chat_channel, user) &&
               @connection.chat_channel.user_chat_channel_memberships.exists?(user_id: user.id)
        return
      end
      "@#{user.username}"
    end

    def link(title, url, identifier: nil)
      if url.present?
        "[#{identifier ? "#{identifier} " : ""}#{title_text(title)}](#{url.gsub(/[()\\\s]/) { |s| ERB::Util.url_encode(s) }})"
      else
        "#{identifier ? "`#{identifier}` " : ""}#{title_text(title)}"
      end
    end

    def self.emoji_pattern
      @emoji_pattern ||= Regexp.union(Emoji.unicode_replacements.keys.sort_by { |key| -key.length })
    end

    def title_text(value)
      # Entity tokens disable Markdown/linkification. Visible spaces neutralize
      # mention, hashtag and emoji triggers, which run after entity decoding.
      value =
        value
          .to_s
          .gsub(/\p{Cf}/, "")
          .truncate(300, omission: "…")
          .gsub(Regexp.union(Emoji.translations.keys.sort_by { |key| -key.length })) do |shortcut|
            shortcut.chars.join(" ")
          end
          .gsub(%r{\[(?=/?[a-z][a-z0-9_-]*(?:[=\]\s]))}i, "[ ")
          .gsub(self.class.emoji_pattern) do |emoji|
            "[#{Emoji.unicode_replacements.fetch(emoji).tr("_", " ")}]"
          end
      value
        .gsub(/[[:space:][:cntrl:]]+/, " ")
        .strip
        .gsub(/([@#:])(?=\S)/, '\\1 ')
        .each_char
        .map { |char| char.match?(/[[:alnum:] ]/) ? char : "&##{char.ord};" }
        .join
    end

    def escape(value)
      title_text(value)
    end
  end
end
