# How it all connects

This page is the map of the workshop. It inventories every asset
deployed, shows the data flow at three zoom levels, and names every
token and endpoint involved. After reading it you should be able to
explain to a colleague what speaks to what, and why.

The same architecture maps to **any application + any CI system** —
the [Apply this to your app](apply-to-your-app.md) page walks the
recipe for swapping Astroshop and GitLab out.

---

## The seven moving parts

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Dev container                               │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ k3d cluster ("enablement")                                     │  │
│  │  ┌──────────────┐  ┌──────────────────┐  ┌──────────────────┐  │  │
│  │  │  Astroshop   │  │   In-cluster     │  │  Locust loadgen  │  │  │
│  │  │ 15+ services │  │     GitLab       │  │  Playwright +    │  │  │
│  │  │ (the app     │  │  + 22 seeded     │  │  HTTP traffic    │  │  │
│  │  │  under load) │  │  projects + CI   │  │  → Astroshop UI  │  │  │
│  │  └──────┬───────┘  └────────┬─────────┘  └───────┬──────────┘  │  │
│  │         │  traces            │ pipelines        │ traffic       │  │
│  │         │ (OneAgent)         │ + events         │               │  │
│  └─────────┼────────────────────┼──────────────────┼───────────────┘  │
│            │                    │                  │                  │
│  ┌─────────┴────┐  ┌────────────┴──┐  ┌────────────┴────────┐         │
│  │  monaco CLI  │  │   dtctl CLI   │  │  bash helpers       │         │
│  │ (config-as-  │  │ (interactive  │  │ (sendDeploymentEvent│         │
│  │  code)       │  │  ops)         │  │ , seedWorkshop…)    │         │
│  └─────────┬────┘  └───────┬───────┘  └────────────┬────────┘         │
└────────────┼───────────────┼───────────────────────┼──────────────────┘
             │ apply         │ describe / query     │ POST events
             ▼               ▼                       ▼
  ╔══════════════════════════════════════════════════════════════════╗
  ║              Dynatrace tenant (geu80787 in this demo)            ║
  ║                                                                  ║
  ║   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐   ║
  ║   │ Settings │  │ Documents│  │Workflows │  │ Events & Davis │   ║
  ║   │  (SRG,   │  │ (dash,   │  │ (the     │  │   (problems,   │   ║
  ║   │  tagging │  │ notebook,│  │  SRG-    │  │    bizevents,  │   ║
  ║   │  rules…) │  │ launch…) │  │  driver) │  │    sdlc evts)  │   ║
  ║   └──────────┘  └──────────┘  └────┬─────┘  └────────┬───────┘   ║
  ║                                    │                  │           ║
  ║                                    │   reads events   │           ║
  ║                                    └─────────────────►│           ║
  ╚══════════════════════════════════════════════════════════════════╝
```

---

## Asset inventory

| # | Asset | Where it lives | Source | Talks to | Auth |
|---|---|---|---|---|---|
| 1 | **Astroshop** (the application) | k3d namespace `astroshop` | `deployApp astroshop` from framework | OneAgent → Dynatrace | classic API token (operator) |
| 2 | **Locust loadgen** | k3d namespace `astroshop-load` | `deployLoadgenerator`; image built from `migrate/astroshop_repos/loadgenerator/` | Astroshop frontend over the cluster ingress | none — internal |
| 3 | **In-cluster GitLab** | k3d namespace `gitlab`, ingress `gitlab.<ip>.sslip.io` | `installGitlab` (helm chart) | runs jobs in pods on the same cluster | local PAT (in k8s secret) |
| 4 | **22 seeded GitLab projects** | 19 under `Otel-App/*`, 3 under `Support/*` | `seedGitlabRepos` from `migrate/{astroshop_repos,support_repos}/` | each other (orchestrator → service repos) | local PAT |
| 5 | **bash helpers in `my_functions.sh`** | dev container | the repo | Events v2 + SDLC ingest endpoints | `DT_API_TOKEN` (events.ingest + openpipeline.events_sdlc.custom) |
| 6 | **monaco** + the monaco config under `migrate/support_repos/dynatrace_env_automation/monaco/` | dev container; `Support/Dynatrace_Monitoring_as_Code` GitLab project re-applies it on commit | github.com/Dynatrace/dynatrace-configuration-as-code | Settings, Documents, Workflows APIs | `DT_PLATFORM_TOKEN` (`dt0s16…`) |
| 7 | **dtctl** + the `dtctl/` YAMLs | dev container + host | github.com/dynatrace-oss/dtctl | same as monaco (documents, settings, workflows) + DQL query endpoint | `DT_PLATFORM_TOKEN` |

### What lands on the Dynatrace tenant

After `bootstrapWorkshop` + `applyMonacoConfig`, the tenant has:

| Resource type | Count | Source folder | Notes |
|---|---:|---|---|
| Settings: `app:dynatrace.site.reliability.guardian:guardians` | 1 | `monaco/init_configs/labs/srg-staging.json` | The 11-objective SRG |
| Settings: `app:dynatrace.gitlab.connector:connection` | 1 | `monaco/init_configs/labs/gitlab-connection.json` | Connector wired with placeholder when on COE |
| Settings: `builtin:tags.auto-tagging` | 1 | `monaco/init_configs/builtintags.auto-tagging/` | The `Astroshop` tag |
| Settings: `builtin:span-attribute` | 197 | `monaco/init_configs/builtinspan-attribute/` | HTTP headers, custom attributes |
| Settings: `builtin:oneagent.features` | 309 | `monaco/init_configs/builtinoneagent.features/` | OneAgent feature flags |
| Settings: `builtin:apis.detection-rules` | 37 | `monaco/init_configs/builtinapis.detection-rules/` | Service detection |
| Request attributes (classic API) | 5 | `monaco/init_configs/request-attributes/` | `LTN`, `TSN`, session-id |
| Workflows | 2 | `monaco/init_configs/labs/srg-workflow.json` + `event-wf.json` | SRG-runner + smoke test |
| Documents — dashboards | 3 from monaco + 2 from dtctl | `document-dashboard/` + `dtctl/dashboards/` | 5 total |
| Documents — notebooks | 2 | `document-notebook/` | DQL playgrounds |
| Documents — launchpads | 1 | `document-launchpad/` | In-product lab guide entry |
| Synthetic monitor + location | 2 | `synthetic-*` | Browser monitor for the purchase flow |
| RUM application | 1 | `application-web/` | Astroshop frontend |
| SLOs | 3 | `dtctl/slos/` (could also be in monaco) | availability, ad-svc latency, error rate |

---

## Data flow #1: deployment event → Davis correlation

What happens when a GitLab pipeline finishes deploying a release.

```
GitLab CI job (.gitlab-ci.yml)
   │ sources my_functions.sh, calls
   │  sendDeploymentEvent 1.12.1 staging cpu
   ▼
POST /api/v2/events/ingest
    Authorization: Api-Token dt0c01.…  (events.ingest scope)
    body: { eventType: CUSTOM_DEPLOYMENT,
            title: "astroshop release 1.12.1 (cpu)",
            entitySelector: "type(SERVICE),entityName.startsWith(astroshop-)",
            properties: { deploymentName, deploymentVersion,
                          deploymentProject, ciBackLink,
                          Release_Stage, PROBLEM, git.commit.id,
                          git.commit.branch, Repository, pr.number,
                          pr.url, pr.title, pr.author, … } }
   │
   ▼
Grail table: dt.davis.events    kind = DEPLOYMENT_EVENT
   │
   ▼ Davis AI correlates time-adjacent problems against this marker
   ▼
Davis Problem card now shows:
    "Deployment: astroshop release 1.12.1 (cpu) — MR !34
     PR: 'switch to async ad cache' by alice@, 5 files changed
     [Open MR] [Diff]
     Change ticket: CHG-1142"
```

**Why the entitySelector matters:** Davis only attaches the deployment
marker to entities that match. On the COE tenant we use a permissive
`entityName.startsWith(astroshop-)` so it lands on anything that
*looks* like Astroshop. In a real tenant monitoring the cluster, the
selector would target the precise Smartscape services.

---

## Data flow #2: pipeline events → CI/CD Observability app

What populates the **CI/CD Observability** community app's pipeline,
job, and PR views.

```
GitLab CI orchestrator pipeline
  Support/Astroshop_Automated_Load_test
  │
  │ for each release variant:
  │   trigger Otel-App/<service> pipeline
  │     in each job, source my_functions.sh
  │     and call:
  │       sendPipelineEvent astroshop-release $CI_PIPELINE_ID … success/failed
  │       sendTaskEvent $rid-build "build" success $pid $rid $pname main 45
  │       sendTaskEvent $rid-deploy …
  │       …
  ▼
POST /platform/ingest/custom/events.sdlc/gitlab
    Authorization: Api-Token dt0c01.…  (openpipeline.events_sdlc.custom scope)
    body: { cicd.pipeline.id, cicd.pipeline.run.id,
            cicd.pipeline.run.outcome, event.category,
            event.type, event.provider, duration,
            start_time, end_time, … }
   │
   ▼
OpenPipeline rules (installed by the app's wizard)
   normalize and route to →
   ▼
Grail table: events            event.kind = SDLC_EVENT
                               event.provider = gitlab
                               event.category = pipeline | task | deployment | guardian
   │
   ▼
CI/CD Observability app
   - Pipeline view: status, runs, history
   - Stage/Job view: outcomes, durations
   - PR view (when `vcs.pr.*` populated)
   - Flamegraph of one run
```

The same flow with `event.provider = github-actions` feeds GitHub
pipelines — the path segment after `events.sdlc/` is the
discriminator. PR-lifecycle events (`event.category = change`) come
from `.github/workflows/pr-events.yml` (or the equivalent GitLab
webhook).

---

## Data flow #3: SRG verdict → pipeline gate → rollback

The "stop bad builds" loop.

```
Deployment event (flow #1) lands
   │
   ▼
Dynatrace Workflow "astroshop staging quality gate Validation"
   (defined in monaco: labs/srg-workflow.json)
   │
   │ triggered by event filter:
   │   event.kind == "DEPLOYMENT_EVENT" and
   │   deploymentProject == "astroshop"
   │
   ├──► task: get_application  (DQL)   ─┐
   ├──► task: get_frontend_svc (DQL)    ├─ resolve target entity
   ├──► task: get_k8s_cluster  (DQL)   ─┘
   ├──► task: previous_succesful_evaluation (DQL)
   ├──► task: run_validation
   │      action: dynatrace.site.reliability.guardian:validate-guardian-action
   │      input: { guardianIdentifier: guardian_astroshop_staging,
   │               timeframe: { from: deploy_ts, to: now } }
   │      → evaluates 11 test-step latency objectives
   │
   ├──► if PASS: task validation_success
   │      └─ emit success bizevent, close loop
   │
   └──► if FAIL: task validation_failure → create_ticket
          action: dynatrace.gitlab.connector:gitlab-issue-create
          input: { connection: gitlab_connection_id,
                   projectId: 3, … }
          → opens an issue in Support/astroshop_release_repo

GitLab pipeline polls the verdict (or waits on a commit status set by
the connector) — `promote-production` runs only if verdict == pass.
```

**What the SRG actually queries** — all 11 objectives share the same
shape, with `request_attribute.TSN` (test-step name) as the
discriminator:

```dql
fetch spans
| filter isNotNull(request_attribute.TSN)
       and contains(request_attribute.LTN, "Astroshop")
       and request_attribute.TSN == "04 - ad service "
| fieldsAdd duration = toDouble(duration) / 1000000   // ns → ms
| summarize { median = round(median(duration), decimals: 0) }
```

Target: median ≤ **1000 ms**, warning at **900 ms**. The bad-build
variants (`cpu`, `memory`, `nplusone`) deliberately push the median
of the relevant step past 1000 ms.

---

## Authentication summary

| Identity | Form | Used by | Stored as |
|---|---|---|---|
| `DT_API_TOKEN` | classic Api-Token `dt0c01.…` with `events.ingest` + `openpipeline.events_sdlc.custom` (+ optional `bizevents.ingest`) | bash helpers, GitHub Actions composite action, GitLab CI scripts | `.devcontainer/.env` mode 0600; gitignored |
| `DT_PLATFORM_TOKEN` | platform OAuth token `dt0s16.…` with platform scopes | monaco, dtctl | `.devcontainer/.env` + `~/.config/dtctl/config` |
| GitLab root PAT | classic token | seed scripts that push repos + create projects | k8s secret `gitlab/ace-gitlab-root-pat` |
| `DT_OPERATOR_TOKEN` | classic Api-Token | Dynatrace Operator (OneAgent install) | `.devcontainer/.env`, also delivered via env to runtime |

Everything ingest-side flows through one token (`DT_API_TOKEN`); everything
platform-config-side flows through another (`DT_PLATFORM_TOKEN`). Two
secrets, end to end.

---

## One-screen recap

| Question | Answer |
|---|---|
| Where do deployment markers come from? | The GitLab job (or any CI job) calls `sendDeploymentEvent` → POST to `/api/v2/events/ingest` |
| What feeds the CI/CD Observability app? | `sendPipelineEvent` / `sendTaskEvent` → POST to `/platform/ingest/custom/events.sdlc/gitlab` |
| What decides pass/fail? | The SRG `Astroshop - Staging - Quality gate` (in monaco) runs 11 DQL latency objectives over the load-test window |
| What runs the SRG? | A Dynatrace Workflow (in monaco) triggered by every `CUSTOM_DEPLOYMENT` event for `deploymentProject == "astroshop"` |
| What happens on FAIL? | The workflow opens a GitLab issue (or dispatches a rollback pipeline) via the GitLab Connector |
| What stops the bad build? | The `promote-production` job in the GitLab CI has `when: on_success` — it never runs if `validate` returned FAIL |

---

## Next

- [Apply this to your app](apply-to-your-app.md) — generic recipe
- [Stop bad builds](stop-bad-builds.md) — the narrative
- [Monaco config](monaco-config.md) — every resource inventoried
- [CI/CD Observability Q&A](cicd-observability.md) — answers to the
  most common customer questions
