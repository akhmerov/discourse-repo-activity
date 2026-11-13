import { apiInitializer } from "discourse/lib/api";
import RepoActivityBridge from "../components/repo-activity-bridge.gjs";

export default apiInitializer((api) => {
  const settings = api.container.lookup("service:site-settings");
  if (
    settings.chat_enabled &&
    settings.repo_activity_enabled &&
    api.getCurrentUser()
  ) {
    api.renderInOutlet("after-main-outlet", RepoActivityBridge);
  }
});
