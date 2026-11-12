# Discourse repository activity

Receive GitHub and GitLab repository activity in Discourse chat. No forge API
requests, access tokens, raw webhook payload storage, or sidebar indicators.
MIT licensed. Requires core Chat.

## Connect a repository

Open a channel's settings and select **Repositories**. Admins and moderators
can manage repositories in channels they can see. With
`discourse-workspace-groups`, channel owners also get this entry in workspace
channel settings. The plugin works independently of workspace groups.

Select GitHub or GitLab, enter the host without a scheme and the repository
path (GitLab supports nested groups), then add the repository. Copy its URL and
secret into the forge's webhook settings. Use JSON and SSL verification.

* GitHub: Pushes, Workflow runs, Pull requests, Issues, Releases.
* GitLab: Push, Tag push, Pipeline, Merge request, Issues, Release events.

Connections are restricted to category channels; direct messages are excluded.
The management dialog contains per-event toggles, an enable switch, secret
regeneration, removal, and the last delivery/error. Regeneration invalidates the
old secret immediately. Secret values are shown only in authorized management
responses with `Cache-Control: no-store`; they never enter viewer snapshots or
MessageBus messages.

## Activity and announcements

Pushes and CI updates on every branch remain quiet. The channel header pill
shows repository activity, default-branch failures and events since the viewer
last opened the popover. Opening acknowledges only the displayed event cursor;
newer concurrent events remain new. Desktop uses a popover and mobile a native
menu dialog. One snapshot request initializes the channel; permission-filtered
MessageBus updates then refresh it, using a snapshot cursor to cover races
before the first poll. Updates are debounced per channel in a background job and
use native Chat publisher permissions. Unread counts are computed in the client;
management permissions come only from the authenticated snapshot.

The popover lists failures first, followed by recent activity, including branch
state, SHA, pusher, failed workflows/jobs, PR/MR pipelines, pushes today, and
recent events. Up to 50 recent events are shown for each repository. A two-day
Redis set of push event IDs keeps daily counts valid after event pruning.

Default-branch CI failures, tags/releases, opened/merged PRs and MRs, and opened
issues are announced by a dedicated bot, coalesced per connection for two
minutes. A release supersedes a matching tag in that window. If a busy window exceeds Chat’s message length limit, the
announcement preserves failure status and as many titles/links as fit, with an
overflow count pointing readers to the popover. Further failures
edit the same alert. Recovery edits it to `fixed in <sha>` and adds a short
thread reply. A quick failure/recovery pair is coalesced into its recovered
state with a thread reply. If the prior failure message was deleted, a lone
recovery is discarded and the incident is cleared. Failure and recovery toggles
are independent of quiet CI recording; ref state is always tracked. The initial failure mentions a pusher only when a
push webhook supplied a case-insensitive matching Discourse username, that
user can see the channel and has channel membership. Titles are rendered as inline code so
forge content cannot inject links, oneboxes, hashtags or mentions. Bodies, diffs and release notes never
enter chat. Only pushes retain the first line of the final commit message in
the quiet summary, as well as SHA and commit count.

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
A daily job retains the newest 50 events per connection and removes non-default
branch refs idle for 14 days. Closed PR/MR refs are deleted immediately.

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
