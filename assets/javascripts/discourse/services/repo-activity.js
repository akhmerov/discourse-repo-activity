import Service, { service } from "@ember/service";
import RepoActivityManager from "../components/modal/repo-activity-manager";

export default class RepoActivityService extends Service {
  @service modal;
  @service siteSettings;

  get enabled() {
    return (
      this.siteSettings.repo_activity_enabled && this.siteSettings.chat_enabled
    );
  }

  manage(channelId) {
    if (this.enabled && channelId) {
      this.modal.show(RepoActivityManager, { model: { channelId } });
    }
  }
}
