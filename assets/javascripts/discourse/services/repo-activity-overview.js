import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { cancel, debounce } from "@ember/runloop";
import Service, { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";

export default class RepoActivityOverview extends Service {
  @service messageBus;

  @tracked channels = {};
  consumers = new Map();
  subscribed = new Set();
  job;
  loading = false;
  again = false;
  generation = 0;

  watch(channels) {
    const token = {};
    this.consumers.set(token, channels);
    if (this.consumers.size === 1) {
      window.addEventListener("focus", this.refreshSoon);
    }
    this.refreshSoon();
    return () => {
      this.consumers.delete(token);
      if (!this.consumers.size) {
        window.removeEventListener("focus", this.refreshSoon);
        cancel(this.job);
        this.generation++;
        this.again = false;
        this.syncSubscriptions({});
        this.channels = {};
      } else {
        this.refreshSoon();
      }
    };
  }

  @action
  refreshSoon() {
    this.job = debounce(this, this.refresh, 200);
  }

  syncSubscriptions(channels) {
    const next = new Set(
      Object.keys(channels).map((id) => `/repo-activity/${id}`)
    );
    for (const channel of this.subscribed) {
      if (!next.has(channel)) {
        this.messageBus.unsubscribe(channel, this.refreshSoon);
      }
    }
    for (const channel of next) {
      if (!this.subscribed.has(channel)) {
        this.messageBus.subscribe(
          channel,
          this.refreshSoon,
          channels[channel.split("/").at(-1)].message_bus_last_id
        );
      }
    }
    this.subscribed = next;
  }

  async refresh() {
    if (this.loading) {
      this.again = true;
      return;
    }
    const ids = [
      ...new Set(
        [...this.consumers.values()].flatMap((channels) =>
          channels()
            .map((c) => c.chat_channel_id)
            .filter(Boolean)
        )
      ),
    ].sort((a, b) => a - b);
    if (!ids.length) {
      return;
    }
    const generation = this.generation;
    this.loading = true;
    try {
      const chunks = [];
      for (let index = 0; index < ids.length; index += 200) {
        chunks.push(
          ajax("/repo-activity/overview.json", {
            data: { channel_ids: ids.slice(index, index + 200) },
          })
        );
      }
      const results = await Promise.all(chunks);
      if (this.consumers.size && generation === this.generation) {
        const channels = Object.assign(
          {},
          ...results.map((result) => result.channels)
        );
        this.channels = channels;
        // Each cursor predates its snapshot: replay only updates racing that request.
        this.syncSubscriptions(channels);
      }
    } catch {
      // A background failure must not interrupt the overview.
    } finally {
      this.loading = false;
      if (this.again && this.consumers.size) {
        this.again = false;
        this.refreshSoon();
      }
    }
  }
}
