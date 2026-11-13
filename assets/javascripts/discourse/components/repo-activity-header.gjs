import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DMenu from "discourse/float-kit/components/d-menu";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import RepoActivityManager from "./modal/repo-activity-manager.gjs";
import RepoActivityPopover from "./repo-activity-popover.gjs";

export function age(value) {
  if (!value) {
    return i18n("repo_activity.no_activity");
  }
  const minutes = Math.max(
    0,
    Math.floor((Date.now() - new Date(value)) / 60000)
  );
  if (minutes < 60) {
    return i18n("repo_activity.minutes", { count: minutes });
  }
  if (minutes < 1440) {
    return i18n("repo_activity.hours", { count: Math.floor(minutes / 60) });
  }
  return i18n("repo_activity.days", { count: Math.floor(minutes / 1440) });
}

export default class RepoActivityHeader extends Component {
  @service messageBus;
  @service modal;

  @tracked data;
  @tracked highlightSince = 0;

  constructor() {
    super(...arguments);
    this.busChannel = `/repo-activity/${this.args.channel.id}`;
    ajax(`/repo-activity/channels/${this.args.channel.id}.json`)
      .then((data) => {
        if (!this.isDestroying) {
          this.data = data;
          // Replay updates since the snapshot began, including before the first poll.
          this.messageBus.subscribe(
            this.busChannel,
            this.receive,
            data.message_bus_last_id
          );
        }
      })
      .catch(popupAjaxError);
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.messageBus.unsubscribe(this.busChannel, this.receive);
  }

  get compactCount() {
    return this.data?.new_count || this.data?.repos?.length || 0;
  }

  get failing() {
    return this.data?.repos?.some((repo) => repo.failing);
  }

  get statusClass() {
    const state = this.failing
      ? "failed"
      : this.data?.repos?.[0]?.default_ref?.ci_state || "none";
    return `repo-activity__pill repo-activity__pill--${state}`;
  }

  get label() {
    const repos = this.data?.repos || [];
    let label;
    if (repos.length === 1) {
      label = i18n("repo_activity.single", {
        name: repos[0].display_name,
        age: age(repos[0].last_activity_at),
      });
    } else {
      label = i18n("repo_activity.multiple", { count: repos.length });
      const count = repos.filter((repo) => repo.failing).length;
      if (count) {
        label = i18n("repo_activity.failing", { label, count });
      }
    }
    return this.data?.new_count
      ? i18n("repo_activity.new_count", { label, count: this.data.new_count })
      : label;
  }

  @action
  async receive(update) {
    if (update.last_seen_event_id !== undefined && this.data) {
      const seen = Math.max(
        this.data.last_seen_event_id,
        update.last_seen_event_id
      );
      this.data = {
        ...this.data,
        last_seen_event_id: seen,
        new_count:
          update.new_count ??
          (this.data.latest_event_id <= seen ? 0 : this.data.new_count),
      };
      return;
    }
    // Fetch private counts rather than broadcasting an unbounded event-ID list.
    const request = (this.refreshRequest || 0) + 1;
    this.refreshRequest = request;
    try {
      const data = await ajax(
        `/repo-activity/channels/${this.args.channel.id}.json`
      );
      if (!this.isDestroying && request === this.refreshRequest) {
        const seen = Math.max(
          this.data.last_seen_event_id,
          data.last_seen_event_id
        );
        this.data = {
          ...data,
          last_seen_event_id: seen,
          new_count:
            seen > data.last_seen_event_id
              ? data.stream.filter((event) => event.id > seen).length
              : data.new_count,
        };
      }
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  async opened() {
    this.highlightSince = this.data.last_seen_event_id;
    const id = this.data.latest_event_id;
    try {
      await ajax(`/repo-activity/channels/${this.args.channel.id}/read.json`, {
        type: "PUT",
        data: { last_seen_event_id: id },
      });
      if (!this.isDestroying) {
        const seen = Math.max(this.data.last_seen_event_id, id);
        this.data = {
          ...this.data,
          last_seen_event_id: seen,
          new_count:
            this.data.latest_event_id <= seen ? 0 : this.data.new_count,
          repos: this.data.repos.map((repo) => ({ ...repo, new_count: 0 })),
        };
      }
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  manage() {
    this.modal.show(RepoActivityManager, {
      model: { channelId: this.args.channel.id },
    });
  }

  <template>
    {{#if @navbar}}
      {{#in-element @navbar insertBefore=null}}
        {{#if this.data.repos.length}}
          <DMenu
            @ariaLabel={{this.label}}
            @identifier="repo-activity"
            @maxWidth={{420}}
            @modalForMobile={{true}}
            @onShow={{this.opened}}
            @placement="bottom-end"
            @triggerClass={{this.statusClass}}
          >
            <:trigger>
              <span class="repo-activity__full-label">{{this.label}}</span>
              <span
                class="repo-activity__compact-label"
              >{{this.compactCount}}</span>
            </:trigger>
            <:content>
              <div class="repo-activity__content">
                <RepoActivityPopover
                  @channelId={{@channel.id}}
                  @data={{this.data}}
                  @highlightSince={{this.highlightSince}}
                />
                {{#if this.data.can_manage}}
                  <DButton
                    class="btn-default repo-activity__manage"
                    @action={{this.manage}}
                    @label="repo_activity.manage"
                  />
                {{/if}}
              </div>
            </:content>
          </DMenu>
        {{/if}}
      {{/in-element}}
    {{/if}}
    {{#if @settings}}
      {{#if this.data.can_manage}}
        {{#in-element @settings insertBefore=null}}
          <DButton
            class="btn-default repo-activity__settings"
            @action={{this.manage}}
            @icon="code-branch"
            @label="repo_activity.manage"
          />
        {{/in-element}}
      {{/if}}
    {{/if}}
  </template>
}
