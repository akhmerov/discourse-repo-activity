import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

const EVENTS = [
  "push",
  "ci",
  "failure",
  "release",
  "tag",
  "pr_opened",
  "pr_merged",
  "issue_opened",
];

export default class RepoActivityManager extends Component {
  @tracked connections = [];
  @tracked loading = true;
  @tracked busy = false;
  formData = { forge: "github", host: "github.com", repo_path: "" };

  constructor() {
    super(...arguments);
    this.refresh();
  }

  get url() {
    return `/repo-activity/channels/${this.args.model.channelId}/connections`;
  }

  get rows() {
    return this.connections.map((connection) => ({
      ...connection,
      instructions: i18n(`repo_activity.instructions.${connection.forge}`),
      toggles: EVENTS.map((key) => ({
        key,
        label: i18n(`repo_activity.event.${key}`),
        enabled: connection.enabled_events.includes(key),
      })),
    }));
  }

  async refresh() {
    try {
      const data = await ajax(`${this.url}.json`);
      if (!this.isDestroying && !this.isDestroyed) {
        this.connections = data.connections;
        this.loading = false;
      }
    } catch (error) {
      popupAjaxError(error);
    }
  }

  async mutate(path, type, data) {
    this.busy = true;
    try {
      await ajax(`${this.url}${path}.json`, {
        type,
        contentType: "application/json",
        data: data ? JSON.stringify(data) : undefined,
      });
      await this.refresh();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.busy = false;
    }
  }

  @action
  add(data) {
    return this.mutate("", "POST", data);
  }

  @action
  rotate(connection) {
    return this.mutate(`/${connection.id}/rotate`, "POST");
  }

  @action
  remove(connection) {
    return this.mutate(`/${connection.id}`, "DELETE");
  }

  @action
  toggleEnabled(connection) {
    return this.mutate(`/${connection.id}`, "PUT", {
      enabled: !connection.enabled,
    });
  }

  @action
  toggle(connection, key) {
    const enabled = connection.enabled_events.includes(key);
    return this.mutate(`/${connection.id}`, "PUT", {
      enabled_events: enabled
        ? connection.enabled_events.filter((event) => event !== key)
        : [...connection.enabled_events, key],
    });
  }

  <template>
    <DModal
      @title={{i18n "repo_activity.manage"}}
      @closeModal={{@closeModal}}
      class="repo-activity__manager"
    >
      <:body>
        {{#if this.loading}}<p>{{i18n "loading"}}</p>{{/if}}
        {{#each this.rows key="id" as |connection|}}
          <section class="repo-activity__connection">
            <h3>{{connection.display_name}}
              ({{connection.host}}/{{connection.repo_path}})</h3>
            <label>{{i18n "repo_activity.webhook_url"}}<input
                readonly
                value={{connection.webhook_url}}
                aria-label={{i18n "repo_activity.webhook_url"}}
              /></label>
            <label>{{i18n "repo_activity.secret"}}<input
                readonly
                value={{connection.secret}}
                aria-label={{i18n "repo_activity.secret"}}
                autocomplete="off"
              /></label>
            <p>{{connection.instructions}}</p>
            <p>{{i18n "repo_activity.last_delivery"}}
              {{connection.last_delivery_at}}</p>
            {{#if connection.last_delivery_error}}<p
                class="alert alert-error"
              >{{connection.last_delivery_error}}</p>{{/if}}
            <label><input
                type="checkbox"
                checked={{connection.enabled}}
                disabled={{this.busy}}
                {{on "change" (fn this.toggleEnabled connection)}}
              />{{i18n "repo_activity.enabled"}}</label>
            <div class="repo-activity__toggles">
              {{#each connection.toggles as |toggle|}}
                <label><input
                    type="checkbox"
                    checked={{toggle.enabled}}
                    disabled={{this.busy}}
                    {{on "change" (fn this.toggle connection toggle.key)}}
                  />{{toggle.label}}</label>
              {{/each}}
            </div>
            <DButton
              @action={{fn this.rotate connection}}
              @disabled={{this.busy}}
              @label="repo_activity.rotate"
              class="btn-default"
            />
            <DButton
              @action={{fn this.remove connection}}
              @disabled={{this.busy}}
              @label="repo_activity.remove"
              class="btn-danger"
            />
          </section>
        {{/each}}
        <h3>{{i18n "repo_activity.add"}}</h3>
        <Form @data={{this.formData}} @onSubmit={{this.add}} as |form|>
          <form.Field
            @name="forge"
            @type="select"
            @title={{i18n "repo_activity.forge"}}
            @validation="required"
            as |field|
          >
            <field.Control as |select|><select.Option
                @value="github"
              >GitHub</select.Option><select.Option
                @value="gitlab"
              >GitLab</select.Option></field.Control>
          </form.Field>
          <form.Field
            @name="host"
            @type="input"
            @title={{i18n "repo_activity.host"}}
            @validation="required"
            as |field|
          ><field.Control /></form.Field>
          <form.Field
            @name="repo_path"
            @type="input"
            @title={{i18n "repo_activity.repo_path"}}
            @validation="required"
            as |field|
          ><field.Control /></form.Field>
          <form.Submit
            @label={{i18n "repo_activity.add"}}
            @disabled={{this.busy}}
          />
        </Form>
      </:body>
    </DModal>
  </template>
}
