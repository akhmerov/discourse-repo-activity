import Component from "@glimmer/component";
import { i18n } from "discourse-i18n";
import { age } from "./repo-activity-header";

export default class RepoActivityPopover extends Component {
  get repos() {
    return (this.args.repos || []).map((repo) => ({
      ...repo,
      state: i18n(
        `repo_activity.state.${repo.default_ref?.ci_state || "none"}`
      ),
      sha: repo.default_ref?.head_sha?.slice(0, 8),
      age: age(repo.last_activity_at),
      jobs: Object.entries(repo.default_ref?.ci_runs || {})
        .filter(([, run]) => run.state === "failed")
        .flatMap(([name, run]) =>
          (run.jobs?.length ? run.jobs : [name]).map((job) => ({
            name: job,
            url: run.url,
          }))
        ),
      prs: repo.refs
        .filter((ref) => ref.kind === "pr")
        .map((ref) => ({
          ...ref,
          state: i18n(`repo_activity.state.${ref.ci_state}`),
        })),
      events: repo.events.map((event) => ({
        ...event,
        isNew: event.id > this.args.highlightSince,
        age: age(event.created_at),
        kindLabel: i18n(`repo_activity.event.${event.kind}`),
      })),
    }));
  }

  <template>
    <div class="repo-activity__popover">
      {{#each this.repos key="id" as |repo|}}
        <section
          class={{if
            repo.failing
            "repo-activity__repo repo-activity__repo--failed"
            "repo-activity__repo"
          }}
        >
          <h3><a
              href={{repo.url}}
              target="_blank"
              rel="noopener noreferrer"
            >{{repo.display_name}}</a></h3>
          <p>{{repo.default_branch}}
            ·
            {{repo.state}}
            ·
            <code>{{repo.sha}}</code>
            ·
            {{repo.default_ref.pushed_by_login}}
            ·
            {{repo.age}}</p>
          <p>{{i18n "repo_activity.pushes_today" count=repo.pushes_today}}</p>
          {{#each repo.jobs as |job|}}
            <p class="repo-activity__failed-job"><a
                href={{job.url}}
                target="_blank"
                rel="noopener noreferrer"
              >{{job.name}}</a></p>
          {{/each}}
          {{#each repo.prs as |ref|}}
            <p>{{i18n
                "repo_activity.pr_state"
                number=ref.pr_number
                state=ref.state
              }}</p>
          {{/each}}
          <ul>
            {{#each repo.events key="id" as |event|}}
              <li
                class={{if
                  event.isNew
                  "repo-activity__event repo-activity__event--new"
                  "repo-activity__event"
                }}
              >
                <span>{{event.kindLabel}}</span>
                {{#if event.summary.url}}<a
                    href={{event.summary.url}}
                    target="_blank"
                    rel="noopener noreferrer"
                  >{{event.summary.title}}</a>{{else}}{{event.summary.title}}{{/if}}
                <small>{{event.actor_login}} · {{event.age}}</small>
                {{#if event.summary.last_commit}}<small
                  >{{event.summary.last_commit}}</small>{{/if}}
              </li>
            {{/each}}
          </ul>
        </section>
      {{/each}}
    </div>
  </template>
}
