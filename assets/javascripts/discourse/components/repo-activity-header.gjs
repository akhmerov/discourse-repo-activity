import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DMenu from "discourse/float-kit/components/d-menu";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import RepoActivityManager from "./modal/repo-activity-manager";
import RepoActivityPopover from "./repo-activity-popover";

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
        if (!this.isDestroying && !this.isDestroyed) {
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

  @action
  receive(data) {
    if (!this.isDestroying && !this.isDestroyed) {
      this.data = data;
    }
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
  async opened() {
    this.highlightSince = this.data.last_seen_event_id;
    const id = this.data.latest_event_id;
    try {
      await ajax(`/repo-activity/channels/${this.args.channel.id}/read.json`, {
        type: "PUT",
        data: { last_seen_event_id: id },
      });
      if (!this.isDestroying && !this.isDestroyed) {
        const seen = Math.max(this.data.last_seen_event_id, id);
        this.data = {
          ...this.data,
          last_seen_event_id: seen,
          new_count: this.data.repos
            .flatMap((repo) => repo.events)
            .filter((event) => event.id > seen).length,
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
            @identifier="repo-activity"
            @label={{this.label}}
            @triggerClass={{this.statusClass}}
            @onShow={{this.opened}}
            @modalForMobile={{true}}
            @placement="bottom-end"
            @maxWidth={{480}}
          >
            <:content>
              <div class="repo-activity__content">
              <RepoActivityPopover
                @repos={{this.data.repos}}
                @highlightSince={{this.highlightSince}}
              />
              {{#if this.data.can_manage}}
                <DButton
                  @action={{this.manage}}
                  @label="repo_activity.manage"
                  class="btn-default repo-activity__manage"
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
            @action={{this.manage}}
            @label="repo_activity.manage"
            @icon="code-branch"
            class="btn-default repo-activity__settings"
          />
        {{/in-element}}
      {{/if}}
    {{/if}}
  </template>
}
