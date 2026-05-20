# Monaco config — the source of truth

[**monaco**](https://github.com/Dynatrace/dynatrace-configuration-as-code)
(Dynatrace Monitoring-as-Code) holds the *authoritative* Dynatrace
platform configuration for this workshop: tagging rules, span/request
attributes, the SRG, the SRG-driving workflow, the GitLab connector,
dashboards, notebooks, synthetic monitors, RUM detection, and more.

When the workshop is deployed end-to-end (`bootstrapWorkshop`), monaco
also gets pushed into the in-cluster GitLab as the
`Support/Dynatrace_Monitoring_as_Code` project; its GitLab CI pipeline
re-applies the config to the configured Dynatrace tenant on every
commit.

The config lives at:

```
.devcontainer/migrate/support_repos/dynatrace_env_automation/monaco/
├── manifest.yml           # which projects, which tenant(s), how to auth
└── init_configs/          # all the configuration content (1 monaco project)
```

## Applying monaco

```bash
# tokens + URL are in .devcontainer/.env (gitignored, 0600)
set -a; source .devcontainer/.env; set +a
applyMonacoConfig            # bash helper from my_functions.sh
# or directly:
cd .devcontainer/migrate/support_repos/dynatrace_env_automation/monaco
monaco deploy manifest.yml --continue-on-error
```

`bootstrapWorkshop` calls `applyMonacoConfig` automatically. The CLI
is installed by `installMonaco` (pinned to v2.28.7 by default).

### Required env vars

| Var | Source | Used for |
|---|---|---|
| `DT_ENVIRONMENT` | `.devcontainer/.env` | platform URL (`https://<id>.apps.dynatrace.com`) — manifest reads it as `DT_PLATFORM_TENANT_URL` |
| `DT_API_TOKEN` | `.devcontainer/.env` | classic Api-Token for legacy settings APIs |
| `DT_PLATFORM_TOKEN` | `.devcontainer/.env` | platform OAuth token (`dt0s16…`) for workflows, documents, app-settings |

Optional (set them when the in-cluster GitLab is reachable from the
target tenant — otherwise placeholders go in, and these resources just
record the connector shape without being functional):

| Var | What |
|---|---|
| `WORKFLOW_ACTOR_ID` | UUID that owns the workflows |
| `GITLAB_EXTERNAL_ENDPOINT`, `GITLAB_HOST`, `GITLAB_PRIVATE_TOKEN` | wire the GitLab connector to a real GitLab |
| `ACTIVE_GATE_NODE_ID` | host running a private ActiveGate, needed by the synthetic monitor |
| `DT_TENANT_URL_NO_HTTP` | used in the JS runtime allow-list (defaults to the platform URL stripped of the scheme) |

## Resources, folder by folder

The `manifest.yml` declares a single project `init_configs` whose
sub-directories each map to a settings schema or document kind.

| Folder | Schema / Kind | Count | What it does |
|---|---|---:|---|
| `builtinapis.detection-rules` | `builtin:apis.detection-rules` | 37 | Custom service detection rules so Astroshop services are recognised and grouped correctly |
| `builtinanomaly-detection-rum-web` | `builtin:anomaly-detection.rum-web` | 1 | RUM anomaly-detection thresholds for the Astroshop frontend |
| `builtindt-javascript-runtime.allowed-outbound-connections` | `builtin:dt-javascript-runtime.allowed-outbound-connections` | 1 | Allow the Workflow JS runtime to reach in-cluster GitLab |
| `builtinoneagent.features` | `builtin:oneagent.features` | 309 | OneAgent feature flags — enables the deep-code-level instrumentation the workshop relies on |
| `builtinrum.web.app-detection` | `builtin:rum.web.app-detection` | 1 | Map the Astroshop frontend hostname → RUM application |
| `builtinspan-attribute` | `builtin:span-attribute` | 197 | Capture HTTP headers + custom attributes on spans (e.g. `LTN`, `TSN` for load-test step naming) |
| `builtinspan-capturing` | `builtin:span-capturing` | 1 | What spans Dynatrace records |
| `builtinspan-context-propagation` | `builtin:span-context-propagation` | 1 | W3C baggage / trace-context propagation rules |
| `builtinspan-entry-points` | `builtin:span-entry-points` | 1 | Which spans are considered service entry points |
| `builtinspan-event-attribute` | `builtin:span-event-attribute` | 4 | Span event attribute capture |
| `builtintags.auto-tagging` | `builtin:tags.auto-tagging` | 1 | Auto-apply `Astroshop` tag to services/processes — drives SRG filters |
| `conditional-naming-processgroup` | classic API: process-group naming | 1 | Process-group names that show in Smartscape |
| `request-attributes` | classic API: request-attributes | 5 | `TSN` (test-step name), `LTN` (load-test name), session-id — the discriminators the SRG DQL queries filter on |
| `request-naming-service` | classic API: service request naming | 1 | How requests get named on Astroshop services |
| `synthetic-monitor` | classic API: synthetic | 2 | The browser monitor that exercises the Astroshop purchase flow |
| `synthetic-location` | classic API: synthetic-location | 1 | Private synthetic location pointing at the in-cluster ActiveGate |
| `application-web` | classic API: application | 1 | The RUM application definition |
| `global` | several | 9 | Cross-cutting environment settings |
| **`labs`** | mixed — see below | 5 | **The workshop deliverables**: SRG + workflows + GitLab connector |
| `document-dashboard` | `document` (kind=dashboard) | 3 | Workshop dashboards: *Traces on Grail*, *Advanced Diagnostics*, *Astroshop loadtest overview* |
| `document-notebook` | `document` (kind=notebook) | 2 | Workshop notebooks (DQL playgrounds) |
| `document-launchpad` | `document` (kind=launchpad) | 1 | In-product launchpad with the lab-guide deep links |

### labs/ — the workshop deliverables

| File | What it is |
|---|---|
| `srg-staging.json` | **The Site Reliability Guardian** — `Astroshop - Staging - Quality gate` with **11 DQL test-step latency objectives** (homepage, get products, get currencies, ad service, add product A, get recommendations, get cart in B, empty cart, add product B, get cart in A, checkout). Each: median latency ≤ 1000 ms target / 900 ms warning. |
| `srg-workflow.json` | **The workflow that runs the SRG per deployment.** Triggered by deployment events, runs the guardian over the load-test window, opens a GitLab issue on FAIL via the GitLab Connector. |
| `event-wf.json` | Smoke-test workflow that fires synthetic events; useful for end-to-end pipeline tests. |
| `gitlab-connection.json` | The GitLab Connector — URL + PAT for the in-cluster GitLab. |
| `config.yaml` | Monaco manifest tying everything together: declares which file maps to which schema, and the dependency between the workflow and the SRG. |

## Why monaco vs dtctl

Both are useful and they're complementary:

- **monaco** ships the *bulk* of the platform config in one operation:
  20+ folders, hundreds of objects, dependency-ordered. The CI pipeline
  inside the seeded `Dynatrace_Monitoring_as_Code` GitLab project
  re-applies on every commit. This is the "source of truth".
- **dtctl** is a kubectl-style CLI for *interactive* day-to-day work:
  `dtctl get workflows`, `dtctl describe slo`, `dtctl apply -f one.yaml`,
  `dtctl query "fetch events …"`. Friendlier for ad-hoc changes and AI
  agents. Mirror configs live under `dtctl/` to demo this workflow.

When in doubt: change monaco first, dtctl second.
