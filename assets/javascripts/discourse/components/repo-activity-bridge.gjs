import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { array } from "@ember/helper";
import { cancel, scheduleOnce } from "@ember/runloop";
import { service } from "@ember/service";
import RepoActivityHeader from "./repo-activity-header";

// This core has no navbar outlet. Keep DOM discovery here; Glimmer owns all UI.
export default class RepoActivityBridge extends Component {
  @service chat;

  @tracked navbar;
  @tracked settings;

  constructor() {
    super(...arguments);
    this.observer = new MutationObserver(() => {
      this.renderJob = scheduleOnce("afterRender", this, this.locate);
    });
    this.observer.observe(document.body, { childList: true, subtree: true });
    this.renderJob = scheduleOnce("afterRender", this, this.locate);
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.observer.disconnect();
    cancel(this.renderJob);
  }

  locate() {
    if (this.isDestroying || this.isDestroyed) {
      return;
    }
    const navbar = document.querySelector(
      ".c-drawer-routes.--channel .c-navbar, .c-routes.--channel > .c-navbar-container .c-navbar"
    );
    const settings = document.querySelector(".c-channel-settings");
    if (this.navbar !== navbar) {
      this.navbar = navbar;
    }
    if (this.settings !== settings) {
      this.settings = settings;
    }
  }

  <template>
    {{#each (array this.chat.activeChannel) key="id" as |channel|}}
      {{#if channel}}
        <RepoActivityHeader
          @channel={{channel}}
          @navbar={{this.navbar}}
          @settings={{this.settings}}
        />
      {{/if}}
    {{/each}}
  </template>
}
