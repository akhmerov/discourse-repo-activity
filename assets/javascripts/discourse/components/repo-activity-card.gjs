import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { i18n } from "discourse-i18n";
import { age } from "./repo-activity-header.gjs";

export default class RepoActivityCard extends Component {
  @service repoActivityOverview;
  @service repoActivityNavigation;
  @service router;

  constructor() {
    super(...arguments);
    this.stop = this.repoActivityOverview.watch(
      () => this.args.outletArgs.channels || []
    );
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.stop();
  }

  get channel() {
    return this.args.outletArgs.channel;
  }

  get data() {
    return this.repoActivityOverview.channels[this.channel.chat_channel_id];
  }

  get repos() {
    return (this.data?.repos || []).slice(0, 4).map((repo) => ({
      ...repo,
      ariaLabel: `${repo.name}: ${i18n(`repo_activity.state.${repo.state}`)}`,
      dot: `repo-activity__dot repo-activity__dot--${repo.state}`,
      failure:
        repo.state === "failed"
          ? i18n("repo_activity.overview_failure", {
              branch: repo.branch,
              age: age(repo.updated_at),
            })
          : null,
    }));
  }

  get more() {
    return Math.max(0, (this.data?.repos.length || 0) - 4);
  }

  get url() {
    return `/chat/c/${this.channel.chat_channel_slug || "-"}/${this.channel.chat_channel_id}`;
  }

  @action
  open(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
      return;
    }
    event.preventDefault();
    this.repoActivityNavigation.channelId = this.channel.chat_channel_id;
    this.router.transitionTo(this.url);
  }

  <template>
    {{#if this.repos.length}}
      <div
        aria-label={{i18n "repo_activity.manage"}}
        class="repo-activity__card"
      >
        {{#each this.repos key="id" as |repo|}}
          <a
            aria-label={{repo.ariaLabel}}
            class="repo-activity__chip"
            href={{this.url}}
            {{on "click" this.open}}
          >
            <span aria-hidden="true" class={{repo.dot}}></span><span
            >{{repo.name}}</span>
            {{#if repo.failure}}<span
                class="repo-activity__chip-failure"
              >{{repo.failure}}</span>{{/if}}
          </a>
        {{/each}}
        {{#if this.more}}<a
            class="repo-activity__chip"
            href={{this.url}}
            {{on "click" this.open}}
          >+{{this.more}}</a>{{/if}}
        {{#if this.data.new_count}}<a
            class="repo-activity__card-new"
            href={{this.url}}
            {{on "click" this.open}}
          >{{i18n
              "repo_activity.overview_new"
              count=this.data.new_count
            }}</a>{{/if}}
      </div>
    {{/if}}
  </template>
}
