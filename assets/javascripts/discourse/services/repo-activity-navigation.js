import { action } from "@ember/object";
import { cancel, next } from "@ember/runloop";
import Service, { service } from "@ember/service";

export default class RepoActivityNavigation extends Service {
  @service router;
  @service chat;
  @service chatStateManager;

  channelId = null;
  expiresAt = 0;
  requestId = 0;
  routeJob;

  constructor() {
    super(...arguments);
    this.router.on("routeDidChange", this.routeDidChange);
  }

  willDestroy() {
    cancel(this.routeJob);
    this.router.off("routeDidChange", this.routeDidChange);
    super.willDestroy(...arguments);
  }

  request(channelId) {
    this.channelId = channelId;
    this.expiresAt = Date.now() + 10000;
    return ++this.requestId;
  }

  cancel(channelId, requestId = this.requestId) {
    if (this.channelId === channelId && requestId === this.requestId) {
      this.channelId = null;
      this.expiresAt = 0;
    }
  }

  consume(channelId) {
    if (Date.now() >= this.expiresAt) {
      this.channelId = null;
      return false;
    }
    if (this.channelId !== channelId) {
      return false;
    }
    this.cancel(channelId);
    return true;
  }

  @action
  routeDidChange() {
    cancel(this.routeJob);
    this.routeJob = next(this, this.checkDestination);
  }

  checkDestination() {
    const destination = this.router.currentURL
      ?.split(/[?#]/)[0]
      .match(/\/chat\/c\/[^/]+\/(\d+)(?:\/|$)/);
    const drawerId = this.chatStateManager.isDrawerExpanded
      ? this.chat.activeChannel?.id
      : null;
    if (
      this.channelId &&
      Number(destination?.[1] || drawerId) !== Number(this.channelId)
    ) {
      this.cancel(this.channelId);
    }
  }
}
