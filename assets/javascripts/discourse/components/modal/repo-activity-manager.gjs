import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { cancel, debounce, later } from "@ember/runloop";
import { service } from "@ember/service";
import Form from "discourse/components/form";
import DMenu from "discourse/float-kit/components/d-menu";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { clipboardCopyAsync } from "discourse/lib/utilities";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import DToggleSwitch from "discourse/ui-kit/d-toggle-switch";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import { parseRepositoryAddress } from "../../lib/repository-address.js";
import { age } from "../repo-activity-header.gjs";

export default class RepoActivityManager extends Component {
  @service dialog;
  @service messageBus;

  @tracked connections = [];
  @tracked loading = true;
  @tracked busy = false;
  @tracked screen = "list";
  @tracked selectedId;
  @tracked address = "";
  @tracked formData = { address: "" };
  @tracked revealedSecret = null;
  @tracked rotated = false;
  @tracked copied = false;

  #renew;
  #refreshJob;
  #subscribed = false;
  #refreshing = false;
  #refreshAgain = false;

  constructor() {
    super(...arguments);
    this.#refresh(false);
  }

  willDestroy() {
    super.willDestroy(...arguments);
    cancel(this.#renew);
    cancel(this.#refreshJob);
    this.messageBus.unsubscribe(this.busChannel, this.receive);
    this.revealedSecret = null;
  }

  get url() {
    return `/repo-activity/channels/${this.args.model.channelId}/connections`;
  }

  get busChannel() {
    return `/repo-activity/management/${this.args.model.channelId}`;
  }

  get parsed() {
    return parseRepositoryAddress(this.address);
  }

  get parsePreview() {
    const repo = this.parsed;
    return repo ? i18n(`repo_activity.manager.preview_${repo.forge}`, repo) : null;
  }

  get rows() {
    return this.connections.map((connection) => ({
      ...connection,
      name: connection.forge === "gitlab" && connection.host !== "gitlab.com" ? `${connection.host}/${connection.repo_path}` : connection.repo_path,
      icon: `fab-${connection.forge}`,
      forgeLabel: connection.forge === "github" ? "GitHub" : "GitLab",
      status: !connection.enabled ? i18n("repo_activity.manager.paused") :
        connection.delivery_status === "waiting" ? i18n("repo_activity.manager.waiting") :
        connection.delivery_status === "receiving" ? i18n("repo_activity.manager.receiving", { age: age(connection.last_delivery_at) }) :
        i18n("repo_activity.manager.rejected", { count: connection.rejected_deliveries, reason: i18n(`repo_activity.manager.reason.${connection.delivery_status}`) }),
      needsSetup: connection.enabled && connection.delivery_status !== "receiving",
      setupLabel: connection.delivery_status === "waiting" ? "repo_activity.manager.finish_setup" : "repo_activity.manager.fix_setup",
      seen: (connection.recent_event_types || []).map((type) => i18n(`repo_activity.manager.seen_types.${type}`)).join(", "),
      statusClass: `repo-manager__status repo-manager__status--${!connection.enabled ? "paused" : connection.delivery_status}`,
    }));
  }

  get current() {
    return this.rows.find((connection) => connection.id === this.selectedId);
  }

  get github() {
    return this.current?.forge === "github";
  }

  get setupUrl() {
    return `${this.current?.repository_url}/${this.github ? "settings/hooks/new" : "-/hooks"}`;
  }

  get missingEvents() {
    return (this.current?.missing_hook_events || []).map((event) => ({
      key: event,
      required: ["push", "workflow_run"].includes(event),
      text: i18n(`repo_activity.manager.missing.${event}`),
    }));
  }


  get triggers() {
    return (this.github ? ["push", "workflow", "pr", "issue", "release"] : ["push", "pipeline", "tag", "mr", "issue", "release"]).map((key, index) => ({
      key,
      label: i18n(`repo_activity.manager.triggers.${this.github ? "github" : "gitlab"}.${key}`),
      required: index < 2,
    }));
  }

  get checkText() {
    const repo = this.current;
    if (repo?.delivery_status === "receiving") {
      return i18n("repo_activity.manager.connected");
    }
    if (repo?.delivery_status && repo.delivery_status !== "waiting") {
      return i18n(`repo_activity.manager.fix.${repo.delivery_status}`);
    }
    return i18n("repo_activity.manager.waiting_test", { forge: this.github ? "GitHub" : "GitLab" });
  }

  @action
  receive() {
    this.#refreshJob = debounce(this, this.#refresh, true, 200);
  }

  @action
  back() {
    this.screen = this.screen === "check" ? "webhook" : "list";
    this.revealedSecret = null;
    this.copied = false;
  }

  @action
  addScreen() {
    this.address = "";
    this.formData = { address: "" };
    this.screen = "repo";
    this.revealedSecret = null;
    this.rotated = false;
  }

  @action
  addressChanged(name, value) {
    this.address = value;
  }

  @action
  async add() {
    if (!this.parsed) {
      return;
    }
    const repo = await this.#mutate("", "POST", this.parsed);
    if (repo) {
      this.selectedId = repo.id;
      this.screen = "webhook";
    }
  }

  @action
  async openScreen(close, connection, screen) {
    await close?.();
    this.selectedId = connection.id;
    this.screen = screen;
    this.revealedSecret = null;
    this.rotated = false;
    this.copied = false;
  }

  @action
  showCheck() {
    this.screen = "check";
    this.revealedSecret = null;
    this.#refresh(true);
  }

  @action
  async rotate(close, connection) {
    await close();
    this.dialog.confirm({
      message: i18n("repo_activity.manager.rotate_confirm"),
      didConfirm: async () => {
        const repo = await this.#mutate(`/${connection.id}/rotate`, "POST");
        if (repo) {
          this.selectedId = repo.id;
          this.revealedSecret = null;
          this.rotated = true;
          this.screen = "webhook";
        }
      },
    });
  }

  @action
  async remove(close, connection) {
    await close();
    this.dialog.confirm({
      message: i18n("repo_activity.manager.remove_confirm", { name: connection.repo_path }),
      didConfirm: () => this.#mutate(`/${connection.id}`, "DELETE"),
    });
  }

  @action
  toggleEnabled(connection) {
    return this.#mutate(`/${connection.id}`, "PUT", { enabled: !connection.enabled });
  }


  @action
  async reveal() {
    if (this.revealedSecret) {
      this.revealedSecret = null;
      return;
    }
    try {
      const id = this.current.id;
      const value = await this.#secret(id);
      if (!this.isDestroying && this.current?.id === id && this.screen === "webhook") {
        this.revealedSecret = value;
      }
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  async copy(kind) {
    try {
      const repo = this.current;
      const settings = this.setupUrl;
      await clipboardCopyAsync(async () => {
        let text;
        if (kind === "url") {
          text = repo.webhook_url;
        } else {
          const secret = await this.#secret(repo.id);
          text = kind === "secret" ? secret : i18n(`repo_activity.manager.copy_steps_${repo.forge}`, {
            settings, url: repo.webhook_url, secret,
          });
        }
        return new Blob([text], { type: "text/plain" });
      });
      this.copied = true;
    } catch (error) {
      popupAjaxError(error);
    }
  }

  async #secret(id) {
    const result = await ajax(`${this.url}/${id}/secret.json`);
    return result.secret;
  }

  async #refresh(silent) {
    if (this.#refreshing) {
      this.#refreshAgain = true;
      return;
    }
    this.#refreshing = true;
    try {
      const data = await ajax(`${this.url}.json`);
      if (!this.isDestroying) {
        this.connections = data.connections;
        this.loading = false;
        if (!this.#subscribed) {
          this.messageBus.subscribe(this.busChannel, this.receive, data.message_bus_last_id);
          this.#subscribed = true;
        }
      }
    } catch (error) {
      if (!silent) { popupAjaxError(error); }
    } finally {
      this.#refreshing = false;
      if (!this.isDestroying) {
        cancel(this.#renew);
        this.#renew = later(this, this.#refresh, true, 120000);
        if (this.#refreshAgain) {
          this.#refreshAgain = false;
          this.receive();
        }
      }
    }
  }

  async #mutate(path, type, data) {
    this.busy = true;
    try {
      const result = await ajax(`${this.url}${path}.json`, {
        type, contentType: "application/json", data: data ? JSON.stringify(data) : undefined,
      });
      await this.#refresh(false);
      return result;
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.busy = false;
    }
  }

  <template>
    <DModal class="repo-activity__manager" @closeModal={{@closeModal}} @title={{i18n "repo_activity.manage"}}>
      <:body>
        {{#if this.loading}}<p>{{i18n "loading"}}</p>{{else}}
          {{#unless (eq this.screen "list")}}
            <DButton class="btn-transparent repo-manager__back" @action={{this.back}} @icon="chevron-left" @label="repo_activity.manager.back" />
          {{/unless}}
          {{#if (eq this.screen "list")}}
            <div class="repo-manager__list">
              {{#each this.rows key="id" as |repo|}}
                <section class="repo-manager__row" data-repo-id={{repo.id}}>
                  {{dIcon repo.icon class="repo-manager__forge"}}
                  <div class="repo-manager__identity">
                    <a class="repo-manager__name" href={{repo.repository_url}} rel="noopener noreferrer" target="_blank">{{repo.name}}</a>
                    {{#if repo.seen}}<p class="repo-manager__seen">{{i18n "repo_activity.manager.seen" types=repo.seen}}</p>{{/if}}
                    <div class={{repo.statusClass}}>{{repo.status}}
                      {{#if repo.needsSetup}} · <DButton class="btn-transparent repo-manager__inline" @action={{fn this.openScreen null repo "webhook"}} @label={{repo.setupLabel}} />{{/if}}
                    </div>
                  </div>
                  <DToggleSwitch aria-label={{i18n "repo_activity.enabled"}} disabled={{this.busy}} @state={{repo.enabled}} {{on "click" (fn this.toggleEnabled repo)}} />
                  <DMenu @ariaLabel={{i18n "repo_activity.manager.actions" name=repo.repo_path}} @icon="ellipsis" @identifier="repo-manager-actions" @inline={{true}} @triggerClass="btn-transparent repo-manager__menu-trigger">
                    <:content as |menu|>
                      <div class="repo-manager__menu">
                        <DButton class="btn-transparent" @action={{fn this.openScreen menu.close repo "webhook"}} @label="repo_activity.manager.setup" />
                        <a href={{repo.repository_url}} rel="noopener noreferrer" target="_blank">{{i18n "repo_activity.manager.open_forge" forge=repo.forgeLabel}} ↗</a>
                        <DButton class="btn-transparent" @action={{fn this.rotate menu.close repo}} @disabled={{this.busy}} @label="repo_activity.manager.new_secret" />
                        <DButton class="btn-transparent btn-danger" @action={{fn this.remove menu.close repo}} @disabled={{this.busy}} @label="repo_activity.remove" />
                      </div>
                    </:content>
                  </DMenu>
                </section>
              {{else}}
                <p class="repo-manager__empty">{{i18n "repo_activity.manager.empty"}}</p>
              {{/each}}
            </div>
            <div class="repo-manager__footer">{{#if this.connections.length}}<span>{{i18n "repo_activity.manager.per_repo"}}</span>{{/if}}<DButton class="btn-primary" @action={{this.addScreen}} @icon="plus" @label="repo_activity.add" /></div>
          {{else if (eq this.screen "repo")}}
            <h3>{{i18n "repo_activity.add"}}</h3>
            <p class="repo-manager__steps">{{i18n "repo_activity.manager.step_repo"}}</p>
            <Form @data={{this.formData}} @onSet={{this.addressChanged}} @onSubmit={{this.add}} as |form|>
              <form.Field @name="address" @title={{i18n "repo_activity.manager.address"}} @type="input" @validation="required" as |field|><field.Control autocomplete="off" placeholder="github.com/owner/repo" /></form.Field>
              <p aria-live="polite" class="repo-manager__preview">{{#if this.parsePreview}}{{this.parsePreview}}{{else if this.address}}{{i18n "repo_activity.manager.invalid_address"}}{{/if}}</p>
              <p class="repo-manager__note">{{i18n "repo_activity.manager.access"}}</p>
              <form.Submit @disabled={{this.busy}} @label={{i18n "repo_activity.manager.continue"}} />
            </Form>
          {{else if this.current}}
            <h3 class="repo-manager__heading">{{this.current.name}}</h3>
            {{#if (eq this.screen "webhook")}}
              <p class="repo-manager__steps">{{i18n "repo_activity.manager.step_webhook"}}</p>
              {{#if this.rotated}}<p class="alert alert-warning">{{i18n "repo_activity.manager.rotated_warning"}}</p>{{/if}}
              <ol class="repo-manager__instructions">
                <li><p>{{i18n "repo_activity.manager.open_settings"}}</p><a class="btn btn-default" href={{this.setupUrl}} rel="noopener noreferrer" target="_blank">{{#if this.github}}{{i18n "repo_activity.manager.open_github"}}{{else}}{{i18n "repo_activity.manager.open_gitlab"}}{{/if}} ↗</a>{{#unless this.github}}<p>{{i18n "repo_activity.manager.gitlab_add"}}</p>{{/unless}}</li>
                <li><label>{{#if this.github}}{{i18n "repo_activity.manager.payload_url"}}{{else}}{{i18n "repo_activity.webhook_url"}}{{/if}}</label><div class="repo-manager__copy-field"><input aria-label={{i18n "repo_activity.webhook_url"}} readonly value={{this.current.webhook_url}} /><DButton class="btn-default" @action={{fn this.copy "url"}} @label="repo_activity.manager.copy" /></div></li>
                {{#if this.github}}<li>{{i18n "repo_activity.manager.content_type"}}</li>{{/if}}
                <li><label>{{#if this.github}}{{i18n "repo_activity.secret"}}{{else}}{{i18n "repo_activity.manager.secret_token"}}{{/if}}</label><div class="repo-manager__copy-field"><input aria-label={{i18n "repo_activity.secret"}} autocomplete="off" class="repo-manager__secret" readonly type={{if this.revealedSecret "text" "password"}} value={{if this.revealedSecret this.revealedSecret "••••••••••••••••"}} /><DButton class="btn-default repo-manager__reveal" @action={{this.reveal}} @label={{if this.revealedSecret "repo_activity.manager.hide" "repo_activity.manager.show"}} /><DButton class="btn-default" @action={{fn this.copy "secret"}} @label="repo_activity.manager.copy" /></div></li>
                <li><p>{{#if this.github}}{{i18n "repo_activity.manager.github_events"}}{{else}}{{i18n "repo_activity.manager.gitlab_events"}}{{/if}}</p>
                  <ul class="repo-manager__triggers">{{#each this.triggers key="key" as |trigger|}}<li><strong>{{trigger.label}}</strong> — {{#if trigger.required}}{{i18n "repo_activity.manager.required"}}{{else}}{{i18n "repo_activity.manager.optional"}}{{/if}}</li>{{/each}}</ul>
                  {{#if this.github}}<p class="repo-manager__note">{{i18n "repo_activity.manager.github_tags"}}</p>{{/if}}
                </li>
                <li>{{#if this.github}}{{i18n "repo_activity.manager.github_finish"}}{{else}}{{i18n "repo_activity.manager.gitlab_finish"}}{{/if}}</li>
              </ol>
              {{#if this.current.seen}}<p class="repo-manager__note">{{i18n "repo_activity.manager.seen" types=this.current.seen}}</p>{{/if}}
              <div class="repo-manager__footer"><DButton class="btn-default" @action={{fn this.copy "instructions"}} @label="repo_activity.manager.copy_instructions" /><DButton class="btn-primary" @action={{this.showCheck}} @label="repo_activity.manager.added" /></div>
              {{#if this.copied}}<p role="status">{{i18n "repo_activity.manager.copied"}}</p>{{/if}}
            {{else if (eq this.screen "check")}}
              <p class="repo-manager__steps">{{i18n "repo_activity.manager.step_check"}}</p>
              <div class="repo-manager__check" role="status">{{this.checkText}}</div>
              {{#each this.missingEvents key="key" as |event|}}<p class={{if event.required "alert alert-warning" "repo-manager__note"}}>{{event.text}}</p>{{/each}}
              <div class="repo-manager__footer"><DButton class="btn-default" @action={{this.receive}} @label="repo_activity.manager.check_again" /><DButton class="btn-primary" @action={{fn this.openScreen null this.current "list"}} @label="repo_activity.manager.done" /></div>

            {{/if}}
          {{/if}}
        {{/if}}
      </:body>
    </DModal>
  </template>
}
