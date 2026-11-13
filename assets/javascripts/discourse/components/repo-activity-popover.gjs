import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import { age } from "./repo-activity-header.gjs";

const symbols = {
  success: "✓",
  failed: "✗",
  pending: "⟳",
  running: "⟳",
  none: "○",
  neutral: "−",
};

export default class RepoActivityPopover extends Component {
  @tracked selected = null;
  @tracked filtered = null;
  @tracked earlier = [];

  @tracked cursor;

  @tracked expanded = new Set();
  @tracked loading = false;
  request = 0;
  @tracked _retained = [];

  constructor() {
    super(...arguments);
    this._retained = this.args.data.stream || [];
  }

  get repos() {
    return (this.args.data.repos || []).map((repo) => ({
      ...repo,
      new_count: (this.args.newCounts?.[repo.id] || 0) + (repo.new_count || 0),
      selected: repo.id === this.selected,
      idle:
        !repo.last_activity_at ||
        Date.now() - new Date(repo.last_activity_at) > 14 * 86400000,
      symbol: symbols[repo.default_ref?.ci_state || "none"],
      stateClass: `repo-activity__dot repo-activity__dot--${repo.default_ref?.ci_state || "none"}`,
      age: age(repo.default_ref?.updated_at || repo.last_activity_at),
    }));
  }

  get activeRepos() {
    return this.repos.filter((repo) => !repo.idle);
  }

  get idleNames() {
    return this.repos
      .filter((repo) => repo.idle)
      .map((repo) => repo.display_name)
      .join(", ");
  }

  get hasEarlier() {
    return this.cursor === undefined
      ? this.args.data.earlier_before
      : this.cursor;
  }

  get groups() {
    const events = this.#merge([
      ...this.earlier,
      ...this._retained,
      ...(this.filtered || this.args.data.stream || []),
    ]).filter((event) => !this.selected || event.connection_id === this.selected);
    const hasNew = events.some((event) => event.id > this.args.highlightSince);
    const groups = [];
    let divided = false;
    for (const event of events) {
      if (this.selected && event.connection_id !== this.selected) {
        continue;
      }
      const isNew = event.id > this.args.highlightSince;
      if (hasNew && !isNew && !divided) {
        groups.push({ id: "seen", divider: true });
        divided = true;
      }
      const repo = this.repos.find((r) => r.id === event.connection_id);
      const previous = groups[groups.length - 1];
      const push = event.kind === "push";
      if (
        push &&
        previous?.push &&
        previous.repoId === event.connection_id &&
        previous.actor === event.actor_login &&
        previous.branch === event.summary.ref &&
        previous.isNew === isNew
      ) {
        previous.commits.push(...[...(event.summary.commits || [])].reverse());
        previous.total += event.summary.commit_count || 0;
        continue;
      }
      groups.push({
        id: event.id,
        repoId: event.connection_id,
        repo: repo?.display_name,
        push,
        actor: event.actor_login,
        branch: event.summary.ref,
        symbol: symbols[event.ci_state || event.summary.ci_state || "none"],
        jobs: Object.values(event.ci_runs || event.summary.ci_runs || {})
          .filter((run) => run.state === "failed")
          .map((run) => ({ name: run.name, url: run.url })),
        age: age(event.created_at),
        isNew,
        label: i18n(`repo_activity.stream_event.${event.kind}`),
        title: event.summary.title,
        url: event.summary.url,
        commits: [...(event.summary.commits || [])].reverse(),
        total: event.summary.commit_count || 0,
      });
    }
    return groups.map((group) => ({
      ...group,
      className: `repo-activity__event${group.isNew ? " repo-activity__event--new" : ""}`,
      commits: (this.expanded.has(group.id)
        ? group.commits
        : group.commits?.slice(0, 3)
      )?.map((commit) => ({ ...commit, short: commit.sha.slice(0, 8) })),
      more:
        !this.expanded.has(group.id) && group.commits?.length > 3
          ? group.commits.length - 3
          : 0,
      omitted: Math.max(0, group.total - (group.commits?.length || 0)),
    }));
  }

  @action
  async select(id) {
    this.selected = this.selected === id ? null : id;
    this.earlier = [];
    this.cursor = undefined;
    this.filtered = null;
    ++this.request;
    if (!this.selected) {
      return;
    }
    await this.refreshFilter();
  }

  @action
  async refreshFilter() {
    const request = ++this.request;
    this.loading = true;
    try {
      const result = this.selected
        ? await ajax(`/repo-activity/channels/${this.args.channelId}.json`, {
            data: { connection_id: this.selected },
          })
        : this.args.data;
      if (request === this.request) {
        const old = this.selected ? this.filtered : this._retained;
        const top = old?.[0]?.id;
        let batch = result;
        let incoming = result.stream;
        // Walk bounded pages back to our retained window. Keeping only the old
        // "earlier" page would lose items displaced by a live burst.
        while (top && batch.earlier_before && batch.stream.at(-1)?.id > top) {
          batch = await ajax(`/repo-activity/channels/${this.args.channelId}.json`, {
            data: { before: batch.earlier_before, connection_id: this.selected },
          });
          if (request !== this.request || this.isDestroying) {
            return;
          }
          incoming = [...incoming, ...batch.stream];
        }
        const merged = this.#merge([...(old || []), ...incoming]);
        if (this.selected) {
          this.filtered = merged;
        } else {
          this._retained = merged;
        }
        if (!this.earlier.length && this.cursor === undefined) {
          this.cursor = batch.earlier_before;
        }
      }
    } catch {
      // A live refresh is best effort; user-initiated pagination reports errors.
    } finally {
      if (request === this.request) {
        this.loading = false;
      }
    }
  }

  @action
  expand(id) {
    this.expanded = new Set([...this.expanded, id]);
  }

  @action
  async loadEarlier() {
    this.loading = true;
    const request = this.request;
    try {
      const result = await ajax(
        `/repo-activity/channels/${this.args.channelId}.json`,
        { data: { before: this.hasEarlier, connection_id: this.selected } }
      );
      if (request === this.request) {
        this.earlier = [...this.earlier, ...result.stream];
        this.cursor = result.earlier_before;
      }
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }

  #merge(events) {
    return [...new Map(events.map((event) => [event.id, event])).values()]
      .sort((a, b) => b.id - a.id);
  }

  <template>
    <div class="repo-activity__popover" {{didUpdate this.refreshFilter @data}}>
      <div class="repo-activity__repos">
        {{#each this.activeRepos key="id" as |repo|}}
          <button
            aria-pressed={{repo.selected}}
            class="repo-activity__repo-row {{if repo.selected 'is-selected'}}"
            type="button"
            {{on "click" (fn this.select repo.id)}}
          >
            <span class={{repo.stateClass}}></span>
            <span class="repo-activity__repo-name">{{repo.display_name}}</span>
            <span class="repo-activity__repo-state">{{repo.default_branch}}
              {{repo.symbol}}
              {{repo.age}}</span>
            {{#if repo.new_count}}<span class="repo-activity__new-count">{{i18n
                  "repo_activity.new_events"
                  count=repo.new_count
                }}</span>{{/if}}
          </button>
        {{/each}}
        {{#if this.idleNames}}<p class="repo-activity__idle">○
            {{this.idleNames}}
            —
            {{i18n "repo_activity.idle"}}</p>{{/if}}
      </div>
      <div class="repo-activity__stream-heading">
        <h3>{{i18n "repo_activity.activity"}}</h3>
        {{#if this.selected}}<DButton
            class="btn-transparent"
            @action={{fn this.select this.selected}}
            @label="repo_activity.all_repos"
          />{{/if}}
      </div>
      <div
        aria-label={{i18n "repo_activity.activity"}}
        class="repo-activity__stream"
        role="region"
      >
        {{#each this.groups key="id" as |group|}}
          {{#if group.divider}}
            <div class="repo-activity__last-visit">{{i18n
                "repo_activity.since_looked"
              }}</div>
          {{else}}
            <article class={{group.className}}>
              {{#if group.push}}
                <div class="repo-activity__group-header"><strong
                  >{{group.repo}}</strong>
                  ·
                  {{group.actor}}
                  →
                  {{group.branch}}
                  · CI
                  {{group.symbol}}
                  <time>{{group.age}}</time></div>
                <ul class="repo-activity__commits">
                  {{#each group.commits as |commit|}}<li><a
                        href={{commit.url}}
                        rel="noopener noreferrer"
                        target="_blank"
                      >{{commit.short}}</a>
                      {{commit.message}}</li>{{/each}}
                </ul>
                {{#unless group.commits.length}}<p
                    class="repo-activity__commit-fallback"
                  >{{group.title}}</p>{{/unless}}
                {{#if group.more}}<DButton
                    class="btn-transparent repo-activity__expand"
                    @action={{fn this.expand group.id}}
                    @translatedLabel={{i18n
                      "repo_activity.more_commits"
                      count=group.more
                    }}
                  />{{/if}}
                {{#if group.omitted}}<p class="repo-activity__omitted">{{i18n
                      "repo_activity.omitted_commits"
                      count=group.omitted
                    }}</p>{{/if}}
                {{#each group.jobs as |job|}}<div class="repo-activity__ci">CI ✗
                    ·
                    <a
                      href={{job.url}}
                      rel="noopener noreferrer"
                      target="_blank"
                    >{{job.name}}</a></div>{{/each}}
              {{else}}
                <p><strong>{{group.repo}}</strong>
                  ·
                  {{group.label}}
                  ·
                  {{#if group.url}}<a
                      href={{group.url}}
                      rel="noopener noreferrer"
                      target="_blank"
                    >{{group.title}}</a>{{else}}{{group.title}}{{/if}}
                  <time>{{group.age}}</time></p>
              {{/if}}
            </article>
          {{/if}}
        {{/each}}
        {{#if this.hasEarlier}}<DButton
            class="btn-default repo-activity__earlier"
            @action={{this.loadEarlier}}
            @disabled={{this.loading}}
            @label="repo_activity.load_earlier"
          />{{/if}}
      </div>
    </div>
  </template>
}
