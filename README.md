# Discourse repository activity

Receive GitHub and GitLab repository activity in Discourse chat. No forge API
requests, access tokens, raw webhook payload storage, or sidebar indicators.
MIT licensed. Requires core Chat.

## Connect a repository

Open a channel's settings and select **Repositories**. Admins and moderators
can manage repositories in channels they can see. With
`discourse-workspace-groups`, channel owners also get this entry in workspace
channel settings. The plugin works independently of workspace groups.

Paste the repository address, then follow the Repo → Webhook → Check screens.
HTTPS addresses, `github.com/owner/repo`, nested GitLab project paths and
`git@host:group/project.git` are accepted. Setup has explicit Show/Copy controls
for the secret, a copyable set of instructions for a repo admin, and a live
verified-delivery check. GitHub accepts JSON or its default form encoding; keep
SSL verification enabled.

- GitHub required triggers: Pushes and Workflow runs. Pull requests, Issues and
  Releases are optional. GitHub sends tags through Pushes too.
- GitLab required triggers: Push events and Pipeline events. Tag push, Merge
  request, Issues and Releases events are optional.

Untick optional triggers on the forge if you do not want them in chat. There are
no duplicated per-connection event settings in Discourse. The list shows recent
received event types and safe delivery diagnostics to channel managers only.

Connections are restricted to category channels; direct messages are excluded.
The management dialog lists each repo compactly, with delivery status, a pause
switch and a menu for setup, a new secret or removal. Guided setup accepts a
single repository address and checks verified deliveries live. Event selection
belongs to the forge's webhook triggers: pushes and pipelines stay in the
header; default-branch failures and received PR/MR, issue, release and tag events
post to chat. Secrets are fetched only on explicit Show/Copy actions.

## Activity and announcements

Pushes and CI updates on every branch remain quiet. The channel header pill
shows repository activity, default-branch failures and events since the viewer
last opened the popover. Opening acknowledges only the displayed event cursor;
newer concurrent events remain new. Desktop uses a 400px popover; mobile uses a
bottom sheet and an explicitly labelled compact count.

The top of the popover contains one filterable row per active repository,
failing first, then most recently active. Repositories idle for fourteen days
fold into one line. The shared Activity stream is newest first, in event-arrival
order, across all branches. Consecutive pushes by the same actor to the same
repository and branch share a header with the latest push's CI state. Three
commits appear initially; expand the rest inline. Each push retains up to twenty
validated commit SHAs, first-line messages, author names/logins and forge URLs,
plus the provider's total count. Commits omitted by the provider remain a count.
Quiet branch CI updates decorate push headers rather than adding timeline rows.
A last-visit divider separates events newer than the opening cursor from seen
activity. Load earlier fetches another thirty stream items, optionally filtered
by repository. Snapshots and permission-filtered MessageBus windows are bounded;
private unread counts and management permission come from authenticated requests.

Default-branch CI failures, tags/releases, opened/merged PRs and MRs, and opened
issues are announced by a dedicated bot, coalesced per connection for two minutes.
A release supersedes a matching tag. Each event gets a short readable line under
a bold repository name; bursts show three lines per kind and summarize the rest.
Length limits preserve alerts and summarize overflow. Disposable CI alerts are
separate messages from durable PR, issue and release announcements.

Recovery **trashes the bot's failure alert** through native Chat services, updating
last-message/read tracking and publishing deletion to clients. No recovery reply
is posted when nobody replied. If a human replied, recovery keeps the alert,
edits it to `fixed in <sha>` and posts a threaded reply. Incident replies acquire
the same connection/channel locks before native thread autosave; a late in-flight
reply can restore an alert deleted during recovery. The incident remains in the
Activity stream. A failure/recovery pair completed before announcement stays quiet.
Default-branch failure and recovery behavior is fixed; pushes and ordinary
pipeline updates never post to chat.

The initial alert mentions a pusher only when a push webhook supplied a matching
Discourse username with visibility and channel membership. Forge-controlled
text uses numeric entities to prevent Markdown and linkification. Visible spaces
neutralize mention, hashtag and emoji triggers (for example `@ all`, `# tag`,
`: smile:`); Unicode emoji become readable bracketed names. Ordinary names and
titles remain plain text, with validated forge links on titles. No invisible
characters or code spans are inserted. Bodies, diffs and release notes are discarded.

GitHub CI combines workflow runs **seen for a commit**: any failed run is red,
successful runs (with any neutral runs) are green, all neutral runs are shown
as cancelled/skipped, otherwise running. Workflows are keyed by workflow ID,
not display name. Cancelled and skipped runs are neutral. This receive-only estimate
cannot know about workflows that have not delivered webhooks. Rerun IDs and
attempts prevent late queued/running deliveries from reverting terminal states.
GitHub PR/fork workflows never update branch refs; unidentified PR workflows
are skipped. GitLab merge-request pipelines without an MR number are skipped.

## Security and lifecycle

`POST /repo-activity/hooks/:public_id` checks GitHub SHA256 HMAC signatures or
GitLab secret tokens in constant time. The public URL identifier is independent
of the secret. Secrets are derived with HMAC from the application secret key,
connection ID and secret version; no connection secret is stored. Changing the
server secret key invalidates all webhook secrets.

All requests to an active connection are limited to 120 per minute before
signature verification; delivery errors are written at most once per minute.

Redis delivery IDs expire after 24 hours. Unsupported events/actions receive
2xx. Disabled connections and missing, archived, read-only or closed channels
reject deliveries without persisting them. Delayed jobs recheck channel state.
Disabling a connection discards pending announcements and incident bookkeeping;
re-enabling does not replay them. Pending work found on an inactive channel is
also discarded. Announcement scheduling uses an expiring Redis key so a stalled
event cannot block later events indefinitely. Idle PR and non-default branch
refs are pruned after 14 days. A failed connection does not abort the daily
prune for other connections.
Webhook request parameters are excluded from Rails' action log. There is no raw
payload debug mode. Links must use HTTPS and the configured repository host/path.

The bot is seeded with its negative user ID in PluginStore. It gains chat
membership only as needed. Announcement services use a guardian scoped to their
connected channel, without staff privileges or backing category/group grants.
Ordinary viewers' visibility checks continue to govern all reads and broadcasts.
A daily job retains fourteen days of events, capped at 500 stored commits and
1,000 events per connection, and removes non-default branch refs idle for fourteen days. Closed PR/MR refs are deleted immediately.

## Extension point

The single `repo_activity_channel_manager` registry modifier receives
`(allowed, chat_channel, user)`. Extend `allowed` using your channel management
policy. The feature plugin separately requires current channel visibility.
Workspace groups uses `can_manage_workspace_channel?` through this hook; it owns
no connection data. Its UI uses the optional `repo-activity` service's
`manage(channelId)` method.

## Local testing

From a Discourse checkout with the plugin mounted under `plugins/`:

```sh
LOAD_PLUGINS=1 RAILS_ENV=test bin/rake db:create db:migrate
pnpm --dir=frontend/discourse build
LOAD_PLUGINS=1 RAILS_ENV=test bin/rake assets:precompile:build_plugins
LOAD_PLUGINS=1 bin/rspec plugins/discourse-repo-activity/spec
bin/lint --fix plugins/discourse-repo-activity
```

The system suite checks desktop/mobile popovers, persistent seen state and live
updates. Backend fixtures cover both forges, verification, deduplication, rate
limits, quiet/loud behavior, CI aggregation, private bot posting, mentions,
coalescing, recovery, retention, permissions and MessageBus audience filtering.

The navbar bridge uses Glimmer `in-element`, with isolated DOM discovery,
because the inspected core has no Chat navbar plugin outlet. A future native
outlet can replace that bridge without changing the UI or API.

See `docs/local-validation.md` for the exact tested core, commands, results and
runtime limitations. No remote deployment is implied by these local checks.

The current guided manager, delivery-status semantics, fixed event rules and
screenshot matrix are documented in [repositories-ui.md](docs/repositories-ui.md).
