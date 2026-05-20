# CI/CD Observability with Dynatrace — Workshop Q&A

This document distills the most common questions teams ask when they start
wiring CI/CD pipelines (GitHub Actions, GitLab, Jenkins, Azure DevOps, …)
into Dynatrace, and answers each from a Dynatrace performance-engineering
perspective. Examples reference the `demo-astroshop-problems` repository,
which deploys the OpenTelemetry demo (Astroshop) on a local k3d cluster,
deliberately rolls out four broken release variants (CPU, memory, n+1,
error), drives load with a locust-based generator, and emits release events
into a Dynatrace tenant via Workflows and the Events v2 API.

The intent is a public, workshop-ready reference — no customer-specific
data appears anywhere in this file.

---

## Table of contents

- [What CI/CD observability gives you](#what-cicd-observability-gives-you)
- [The Dynatrace CI/CD observability model](#the-dynatrace-cicd-observability-model)
- [Personas — what each role wants to see](#personas--what-each-role-wants-to-see)
- [PR and change details on Davis problem tickets](#pr-and-change-details-on-davis-problem-tickets)
- [The 11 open questions and their answers](#the-11-open-questions-and-their-answers)
- [Reference architecture for this repo](#reference-architecture-for-this-repo)
- [Workshop demo flow (60 min)](#workshop-demo-flow-60-min)
- [Resources](#resources)

---

## What CI/CD observability gives you

Four outcomes are repeatable across customers, and they map directly to
the DORA metrics SREs are usually asked to report on:

| Outcome | DORA metric it powers |
|---|---|
| Automatically link deployments to production problems | Change Failure Rate, MTTR |
| Measure DORA / SRE metrics from real pipeline data | Deployment Frequency, Lead Time for Changes |
| Detect risky releases early and consistently | Change Failure Rate (predictive) |
| Shift security and quality feedback left | (governance / risk) |

The signal model that underpins these is three layers wide:

1. **Deployment events** — structured `CUSTOM_DEPLOYMENT` events sent to
   Dynatrace at the moment of a release. Carry commit, branch, repo,
   environment, version, and pipeline URL. Davis correlates production
   problems against these timestamps.
2. **Pipeline execution signals** — workflow and job-level events ingested
   via webhooks (GitHub) or job hooks (GitLab/Jenkins/ADO) into Dynatrace
   OpenPipeline. These power lead-time, failure-rate, and queue-depth
   analyses.
3. **Security and quality signals** — Snyk/CodeQL/SonarQube/Trivy results
   ingested as logs or events alongside runtime signals so risk can be
   reasoned about end-to-end.

---

## The Dynatrace CI/CD observability model

```
+-------------------+          +---------------------+         +----------------------+
|   CI/CD system    |          |     Dynatrace       |         |  Production runtime  |
|  (GitHub/GitLab)  |          |     platform        |         |  (k8s, hosts, apps)  |
+-------------------+          +---------------------+         +----------------------+
        |                                |                                |
        | 1. CUSTOM_DEPLOYMENT event     |                                |
        |------------------------------->| Events v2                      |
        |                                |                                |
        | 2. workflow_run / job webhooks |                                |
        |------------------------------->| OpenPipeline (SDLC events)     |
        |                                |                                |
        | 3. Snyk / CodeQL findings      |                                |
        |------------------------------->| security.events ingest         |
        |                                |                                |
        |                                | 4. Davis AI correlates         |
        |                                |    deployment -> problem ----->|
        |                                |                                |
        |                                | 5. SRG validates SLOs against  |
        |<-------------------------------|    runtime + load test data    |
        |   PASS/WARN/FAIL via API/connector                              |
        | 6. Pipeline halts/promotes based on result                      |
```

---

## Personas — what each role wants to see

CI/CD observability is "the same data, three views". Each persona asks
different questions of the same underlying SDLC + deployment + runtime
signals. If you build the data model around the **developer** persona
and bolt on aggregates for the **CI/CD SRE** and **engineering lead**,
the result is reusable across all three.

### Developer

| Question | Where the answer lives | Signal needed |
|---|---|---|
| "Is my PR safe to merge?" | SRG verdict on the PR check | SLOs evaluated over the load-test window; pipeline-run SDLC event with `vcs.pr.number` |
| "Did my deploy cause this problem?" | Davis problem card → linked deployment event | `CUSTOM_DEPLOYMENT` with `pr.*` + `git.commit.*` properties |
| "Which line of code did this?" | Trace → method-hotspots → permalink to git blame | OneAgent code-level traces + git commit on the deployment event |
| "How long is my CI taking compared to last week?" | Pipeline Observability app, filter by author | Pipeline + task SDLC events with `ext.pipeline.run.trigger.user` |
| "Are any of my tests flaky?" | Pipeline app, filter by `task.outcome == failed` over time | Task SDLC events with `task.retry` |

What developers consistently complain about:
- Adding observability config to every PR (counter: ship the reusable
  workflow once; developers just `uses:` it).
- Reading dashboards built for SREs (counter: a *developer dashboard*
  with their PRs, their services, their problems).

### CI/CD SRE / Platform engineer

| Question | Where | Signal |
|---|---|---|
| DORA four keys per team | DORA dashboard from this repo's `dtctl/dashboards/cicd-overview.yaml` | Deployment + SDLC events with `deploymentProject` |
| Pipeline duration / queue depth | Pipeline Observability app | Pipeline + task SDLC events with `start_time` / `end_time` |
| Change Failure Rate by service | DQL: `events | filter event.kind=="DEPLOYMENT_EVENT"` joined with Davis problems opened within N minutes | CUSTOM_DEPLOYMENT + Davis problems |
| Which release introduces the most regressions? | DQL on `srg_verdict == "FAIL"` grouped by `deploymentProject` | Workflow-emitted bizevent for verdict |
| Is our pipeline observability *itself* healthy? | DQL: count of pipeline events ingested vs expected | SDLC ingest health |

### Engineering lead

| Question | Where | Signal |
|---|---|---|
| Are we shipping faster or slower this quarter? | DORA dashboard, 90-day trend | All of the above, aggregated |
| Which teams are blocked at the gate? | SRG verdict timeline | Workflow bizevent + service ownership tag |
| Are we adding risk faster than we burn it down? | Vulnerabilities trend vs deployment rate | Snyk / native scan events alongside deployment events |
| How fast do we recover when things go wrong? | MTTR tile of the CI/CD overview dashboard | `recovery_timestamp - deployment timestamp` for problems linked to deployments |

The trick for the engineering lead view: keep it to **four to six tiles
at most**. Anything more and they stop opening it.

---

## PR and change details on Davis problem tickets

The single highest-leverage thing you can do for the on-call experience
is making sure that the Davis problem card answers the first question
anyone asks: **"which change caused this?"**

### What lands on the problem card today (out of the box)

Davis already correlates each problem against deployments in the
affected entity's history. The problem UI shows:

- Deployment timestamp + name (from `CUSTOM_DEPLOYMENT`)
- Linked entity (the service whose health changed)
- "Affected releases" list

That gets you *that a deployment happened around the time of the
problem*. It doesn't yet tell you *which PR introduced it*.

### What you add with this repo's GitHub Action

`.github/actions/dt-deployment-event/action.yml` enriches the
`CUSTOM_DEPLOYMENT` payload with PR + change metadata that surface as
key/value pairs on the problem card under "Event properties":

| Property | Source | Why it matters |
|---|---|---|
| `pr.number` | `github.event.pull_request.number` or resolved via `gh api .../commits/<sha>/pulls` | Link to the PR from the problem |
| `pr.url` | github.event.pull_request.html_url | One-click to the PR |
| `pr.title` | github.event.pull_request.title | Human-readable context — "PR #234: switch to async ad cache" |
| `pr.author` | github.event.pull_request.user.login | Who to ping |
| `pr.files_changed` | github.event.pull_request.changed_files | Quick risk assessment |
| `pr.merged_at` | github.event.pull_request.merged_at | Timeline anchor |
| `git.commit.id` | github.sha | Permalink to the diff |
| `git.commit.message` | `git log -1 --pretty=%s` | First-line summary |
| `git.commit.branch` | github.ref_name | Branch context |
| `change.ticket` | action input | Jira/ServiceNow change ID if you have one |

These are also indexed in Grail so DQL queries on the events table can
group problems by author, file count, or change ticket.

### How the on-call experience changes

**Before** (raw deployment marker):
> Problem P-1234 on service astroshop-adservice. Deployment "astroshop release 1.12.1" 8 minutes ago.

**After** (with PR enrichment):
> Problem P-1234 on service astroshop-adservice.
> Deployment "astroshop release 1.12.1 — PR #234".
> PR #234: *"switch to async ad cache"* by `alice@`, 5 files changed,
> merged at 14:55Z. [Open PR](https://github.com/...) · [Diff](https://github.com/.../commit/abc1234)
> Change ticket: `CHG-1142`.

That's the difference between "page someone awake and ask them to
investigate" and "page someone awake with the link to the PR already
in their notification".

### The PR lifecycle workflow

`.github/workflows/pr-events.yml` fires a CHANGE event to the CI/CD
Observability app on every `opened` / `synchronize` / `closed` PR
action, so the app's PR view shows the PR independently of any
deployment, with `event.category == "change"`. This gives the
engineering lead a separate timeline of *intent to change* alongside
the *actually deployed* timeline.

### Tenant-side configuration to surface these on the problem card

1. **Notification template** — add `{ProblemEvents}` placeholder in the
   Slack / Teams / email problem notification so the PR fields show in
   the body of the alert.
2. **OpenPipeline rule** — optional: enrich the deployment event by
   joining against the latest `change.ticket` from your ticket system
   if you don't fire it from the pipeline.
3. **Davis problem comments via Workflow** — for a slicker UI, the
   `on-deployment-event.yaml` workflow can post the PR metadata as a
   Davis problem comment when a problem opens within N minutes of a
   deployment.

---

## The 11 open questions and their answers

### Q1. Is the link between deployments and production problems purely dependent on manually sending `CUSTOM_DEPLOYMENT` events through the Events API? Or is there an automated mechanism in the SDLC pipelines that creates deployment markers automatically?

**Short answer:** Both exist, and you almost always want both layers.

1. **Automatic correlation, no events required.** Dynatrace already knows
   when a process or container restarts, when an image tag changes on a
   pod, and when an Azure App Service revision flips. Davis treats these
   as implicit deployment boundaries and correlates problems against them.
   No code, no API, no events. This is your floor.
2. **Explicit `CUSTOM_DEPLOYMENT` events.** Layered on top, you send one
   event per "logical release" so Davis (and your dashboards) can group
   pods that came from the same pipeline run, attribute a problem to a
   specific commit, and reason at the granularity *you* care about — not
   only at the granularity of "a pod restarted".

**Why you want both:** The implicit layer is free and catches everything,
including hotfixes done outside the pipeline. The explicit layer adds
*business context* (pipeline URL, commit, ticket ID, change ticket,
release version) that Davis surfaces in the Problems UI and that you can
query in DQL.

**Reference in this repo:**
[`.devcontainer/migrate/support_repos/automated_load_test/scripts/event.sh`](../.devcontainer/migrate/support_repos/automated_load_test/scripts/event.sh)
shows the pattern — a workflow run is triggered via the Automation API,
which then posts the `CUSTOM_DEPLOYMENT` event with `Release`,
`Pipelineurl`, `stage`, `Repository`, `Release_Version`, and
`Application` properties.

---

### Q2. How do we send `CUSTOM_DEPLOYMENT` events? Do we configure this globally or per repository? How do we reduce developer overhead?

**Short answer:** Centralize the implementation, distribute via a
reusable workflow / shared action / library — developers add one line.

**Three implementation patterns, ranked by how well they scale:**

1. **(Recommended) Reusable workflow / shared action.** Build it once,
   call it from every repo. In GitHub Actions:

   ```yaml
   # In every service repo, a single job:
   jobs:
     notify-deploy:
       uses: my-org/.github/.github/workflows/dt-deployment-event.yml@v1
       with:
         environment: production
         application: ${{ github.event.repository.name }}
   ```
   Developers don't see Dynatrace at all — secrets, payload shape, retry
   logic, and field naming all live in the central workflow.

2. **Pipeline-side helper script.** A bash/PowerShell helper that wraps
   the `POST /api/v2/events` call (or `dtctl apply -f event.yaml`). Lives
   in a shared `ci-tools` repo and is curl'd into each pipeline. Simpler
   to ship than a reusable workflow but the API surface is exposed to the
   repo.

3. **Per-repo bespoke script.** Avoid. Drift is guaranteed within months.

**Field-naming convention we recommend (matches what this repo emits):**

| Property | Source | Example |
|---|---|---|
| `event.type` | hard-coded | `CUSTOM_DEPLOYMENT` |
| `deploymentName` | pipeline | `astroshop release 1.12.1` |
| `deploymentVersion` | git tag / build var | `1.12.1` |
| `deploymentProject` | repo name | `astroshop` |
| `ciBackLink` | pipeline URL | `${CI_JOB_URL}` |
| `remediationAction` | rollback URL | `${ROLLBACK_URL}` |
| `Release_Stage` | env name | `staging` / `production` |
| `git.commit.id` | `${{ github.sha }}` | `abc123…` |
| `git.commit.branch` | `${{ github.ref_name }}` | `main` |

These are searchable in Grail with DQL such as:

```dql
fetch events, from:now() - 24h
| filter event.kind == "DEPLOYMENT_EVENT" and deploymentProject == "astroshop"
| sort timestamp desc
```

**Authentication:** prefer an **OAuth client + access token** for v2
endpoints. Scope it tightly (`events.ingest`) and rotate via your
secrets manager. Don't bake API tokens into repos.

**PoC plan inside this repo:**
1. `installDtctl` (added to `.devcontainer/util/my_functions.sh`) gives
   us a CLI in the dev container.
2. A reusable GitHub Action under `.github/actions/dt-deployment-event/`
   wraps the call.
3. `dtctl/events/sample-deployment.yaml` is committed and exercised
   from a sample workflow under `.github/workflows/`.

---

### Q3. Is "security and quality signals" what the Snyk extension provides? It asks for an ActiveGate group. How does that data route to OpenPipeline?

**Short answer:** Snyk is one provider. Multiple security signals reach
OpenPipeline through different doors.

**Three ingestion paths for security data:**

| Source | Path | When to use |
|---|---|---|
| **Snyk extension** | Snyk → ActiveGate (pull from Snyk API) → Dynatrace `security.events` table | If Snyk is your SCA/Container-scan tool and you want Dynatrace to *pull* findings on a schedule |
| **CI-pushed findings** | Pipeline runs `snyk test --json` → posts to `/platform/ingest/v1/security.events` | Findings arrive on every build, tied to the same release context as the deployment event |
| **Native Dynatrace App/Container/Code-level vulnerabilities** | OneAgent / RVA scanner | Always-on, no setup. Use as the *truth source* for what's actually exposed in production |

**The ActiveGate group** is there because Snyk's API is queried *from*
the ActiveGate, not from your tenant. The group lets you scope which AG
talks to Snyk (e.g., dedicated security AGs in a hardened network zone).

**How it reaches OpenPipeline:** The Snyk extension writes events into
the built-in `security.events` ingest endpoint (`/platform/ingest/v1/security.events`).
From there, OpenPipeline is *the* place you reshape, enrich, route, or
fan-out those events — for example, joining them with the deployment
event so a build that introduced a critical CVE is tagged "risky" before
it reaches production.

**Recommendation:** Build CI-pushed findings *and* the Snyk extension in
parallel. They complement each other:
- CI-push = real-time risk at build time.
- Snyk extension = backstop / scheduled reconciliation, catches drift.

---

### Q4. Does the ingestion source itself determine how data is normalized for CI/CD observability?

**Short answer:** Yes — pick the *purpose-built* endpoint for each
signal so the platform applies the right schema, and don't fan everything
through one generic ingest URL.

| Signal | Endpoint | Result table / kind |
|---|---|---|
| Deployment | `POST /api/v2/events` (event.type=CUSTOM_DEPLOYMENT) | Events, kind=DEPLOYMENT_EVENT |
| Pipeline run / job | `POST /platform/ingest/v1/events.sdlc` | Events, kind=SDLC_EVENT |
| Security finding | `POST /platform/ingest/v1/security.events` | security.events |
| Logs (general) | OTLP / log ingest | logs |
| Custom business event | `POST /platform/ingest/v1/events` (Bizevents) | bizevents |

Each endpoint owns: schema validation, default attribute extraction,
default retention, and which apps surface it. Misroute a deployment as a
plain log and you lose the auto-correlation with Davis problems; misroute
a security finding as a deployment event and the Security Investigator
app won't see it.

**OpenPipeline** can rewrite/route data *after* ingestion, but it can't
recover schema fields you didn't send.

**Rule of thumb:** signal type → endpoint → schema. OpenPipeline is for
enrichment and routing, not for fixing up sloppy ingestion.

---

### Q5. Are there guidelines / best practices for designing the GitHub Actions that fire these events? Naming conventions, when to fire, etc.?

Yes. The ones that survive contact with reality:

**When to fire:**
- **Deployment event:** the moment the artifact lands in the target
  environment — *after* the rollout has reported success, *before* you
  start the post-deploy validation. Firing too early (e.g., when the
  workflow starts) creates phantom deployments if the job is cancelled.
- **Start-of-test event:** when synthetic / load tests start. Lets you
  bound the analysis window for SRG.
- **End-of-test event:** when they complete. SRG uses the
  `from`/`to` from these events.
- **Promotion / rollback events:** the *human-meaningful* moments. Not
  technical ones.

**Naming conventions:**
- Workflow file name: `dt-<action>.yml` (e.g., `dt-deployment-event.yml`).
- Action inputs: lower_snake_case (`application`, `release_version`,
  `git_commit_sha`).
- Event property keys: `dot.notation` matching OTel conventions where they
  exist (`git.commit.id`, `service.name`, `deployment.environment`).
- Version strings: SemVer if you can; otherwise build IDs that sort
  lexicographically.

**Defensive design:**
- Always provide a fallback for `ciBackLink` so you never lose the link
  between an event and the pipeline that fired it.
- `continue-on-error: true` for the Dynatrace step. The deploy succeeds
  even if Dynatrace ingest is briefly unavailable — observability should
  never block delivery.
- Retry with exponential backoff (3 attempts, jitter).
- Emit one event per *logical release*, not one per service in a
  monorepo, unless services release independently.

**Two action implementations to consider:**

1. **Composite action that wraps curl** — simplest, no Docker, runs on
   any runner.
2. **Docker action that wraps `dtctl`** — richer (can read existing
   workflows, do diff/apply), but ties you to runners that can run
   Docker.

---

### Q6. To use SRG (SLO-based quality gates) properly, what do we depend on — synthetic monitor, continuous testing, etc.?

**Short answer:** SRG is a function of SLOs and SLOs need *signal*.
Without signal, SRG passes everything because every guardian is "OK by
default". Three categories of signal feed it:

1. **Runtime signal (free).** OneAgent on the workloads. Gets you the
   four Golden Signals (latency, traffic, errors, saturation) for every
   service automatically. Use this to gate releases against the
   environment's behavior.
2. **Load test signal.** Sustained, repeatable traffic so latency
   percentiles converge. Without this, an SRG that gates on p95 will be
   noisy because a quiet environment has small samples. This repo ships a
   locust-based generator that exercises Astroshop's purchase flow with
   `WebsiteBrowserUser` (Playwright headless), which produces realistic
   end-to-end traces.
3. **Synthetic signal.** HTTP and full-browser checks that verify the
   app is *available* and that critical user journeys work. Use these
   for SLOs about availability and journey success, especially when
   organic traffic is low.

**Optional but high-value:**
- **Business / KPI signal.** A conversion-rate or revenue SLI lets SRG
  reason about user impact, not just technical health. The Astroshop's
  `purchase_completed` business event is the canonical example.
- **Quality / security signal.** Snyk/CodeQL findings as SLI inputs
  (e.g., "zero new criticals" must be ≤ 0).

**Anti-patterns to avoid:**
- Gating on raw counters (`error_count`) instead of ratios (`error_rate`)
  — counters scale with traffic, so an SRG over a quiet weekend can
  green-light a regression.
- Using averages instead of percentiles for latency.
- Defining the SLO target as "this week's value minus 5%" — that's a
  ratchet that always passes the *first* time and never the second.

---

### Q7. We want to block a production pipeline based on an SRG evaluation that ran post-staging deployment. How do we do that in GitHub Actions? What does it depend on?

**Two integration patterns. Pick one per team.**

**Pattern A — pipeline polls Dynatrace (pull):**
```yaml
- name: Trigger SRG
  run: dtctl execute guardian release-readiness --from $START --to $END
- name: Wait for verdict
  run: |
    while [ "$(dtctl get evaluation $ID -o json | jq -r .state)" = "RUNNING" ]; do
      sleep 10
    done
- name: Fail if not PASS
  run: |
    verdict=$(dtctl get evaluation $ID -o json | jq -r .verdict)
    [ "$verdict" = "PASS" ] || exit 1
```
Pros: pipeline-native, easy to debug. Cons: long-running job consumes a
runner.

**Pattern B — Dynatrace Workflow calls back into GitHub (push):**
The Dynatrace Workflow that runs the guardian uses the *Dynatrace GitHub
Connector* to set a commit status or dispatch a `repository_dispatch`
event. The promotion job in GitHub waits on that status check.

Pros: no polling, no idle runners. Cons: more moving parts, callback
auth to manage.

**Dependencies in either case:**
- An SLO definition (`dtctl apply -f slo.yaml`).
- An SRG / guardian (`dtctl apply -f guardian.yaml`) that references the
  SLO objectives.
- A *signal source* — load test or synthetic — that runs *between*
  `START` and `END` so the SLO has data points to evaluate against.
- A `START_TEST` / `END_TEST` event pair so the guardian's time window
  is well-defined (see `event.sh` in this repo for the pattern).
- OAuth client (`automation:workflows:run`) for the workflow path.

**This repo will ship both patterns under `dtctl/guardians/`.**

---

### Q8. Flow: post-prod deployment → execute SRG on SLOs → trigger rollback. What are the dependencies?

This is the same building blocks as Q7 plus a rollback hook. The end-to-
end loop:

```
deploy(prod)
  └─> CUSTOM_DEPLOYMENT event (Release_Stage=production)
       └─> Dynatrace Workflow trigger "deployment in prod"
            ├─> wait for soak window (10-30 min)
            ├─> evaluate guardian (SLOs over the soak window)
            ├─> if FAIL:
            │     ├─> create Davis problem (severity=ERROR_EVENT)
            │     ├─> notify on-call (Slack/PagerDuty action)
            │     └─> trigger rollback action:
            │          - GitHub Connector → re-run "rollback-to-previous"
            │            workflow with previous version as input
            │          - or call ArgoCD `app rollback` via REST
            │          - or `kubectl rollout undo` from a controlled runner
            └─> if PASS: emit "promoted" bizevent and close the loop
```

**Dependencies:**
- SLOs already exist (otherwise the guardian has nothing to evaluate).
- A *previous good version* is identifiable. Easiest: the
  `CUSTOM_DEPLOYMENT` payload from the previous successful release lives
  in Grail; the Workflow queries for the last `result=PASS`.
- The rollback action is idempotent and safe to call from automation.
  This is the part teams usually *don't* have — they have to build the
  inverse of their deploy job. Build it once, treat it as a peer of
  deploy.
- OAuth scopes for `automation:workflows:run`,
  `events.ingest`, and whatever the rollback connector needs.

**Risk to flag:** automated rollback on a regression that the SLO
*incorrectly* believes is real (e.g., a quiet-traffic false negative)
can be more disruptive than the regression. Start with rollback gated on
human approval (`Connector → "Open PR" → human merges` pattern).
Promote to fully automated only once the SLOs have demonstrated low
false-positive rates over multiple cycles.

---

### Q9. Is the GitHub pipeline-observability tutorial the recommended path?

**Yes, if** GitHub is the CI/CD system of record and the team is
comfortable with workflows + webhooks. The tutorial wires:

- `workflow_run` and `workflow_job` GitHub webhooks → Dynatrace
  OpenPipeline.
- OpenPipeline parses them into `dt.entity.cloud.github_workflow_run`
  events and links runs to jobs.
- A built-in dashboard ships under "Pipeline Observability" in the
  Dynatrace Hub.

**Caveats:**
- GitHub webhooks need a public endpoint your Dynatrace tenant can
  receive. Either:
  - Use the Dynatrace-managed webhook endpoint on
    `*.live.dynatrace.com` (recommended), or
  - Front it with an ActiveGate / reverse proxy if your org won't allow
    GitHub to call SaaS directly.
- The default schema is good but specific to GitHub Actions —
  cross-tool aggregation (GitHub + Jenkins + GitLab) needs a normalized
  schema layer in OpenPipeline.
- For private repos, you need a GitHub App or PAT with
  `repo`/`actions:read` scopes.

**Recommendation:** use the tutorial as your *baseline*, and design an
OpenPipeline rule that normalizes pipeline events from *any* CI system
to a single schema (`ci.system`, `ci.pipeline.id`, `ci.run.id`,
`ci.job.id`, `ci.outcome`, `ci.duration`). Dashboards then work
regardless of CI vendor.

---

### Q10. For the Events API, what's the recommended approach (curl / PowerShell / cmd)? Who configures it, and where? Specific use case only, or central?

**Recommended approach, in priority order:**

1. **`dtctl apply -f event.yaml`** — declarative, reviewable, diff-able,
   AI-agent friendly. Same shape works in GitHub Actions, GitLab CI,
   Jenkins, Azure Pipelines.
2. **Official GitHub Action** (`dynatrace-ace/dt-deployment-event` or
   the dtctl-based equivalent) — wraps the call with sensible defaults.
3. **Raw curl** — fine as a fallback, but you re-implement retry, auth
   refresh, and payload validation yourself.

PowerShell or `cmd.exe` are last-resort options used only because a
Windows-only build agent has nothing else. They work, but you'll
re-write them when you migrate runners.

**Who configures it:**
- **Platform / Observability team** owns the central reusable workflow,
  the OAuth client, the secret, and the payload schema.
- **Service teams** consume it by calling the workflow with a couple of
  inputs (`application`, `environment`). They never touch the API
  directly.

**Where it's done in the code:**
- The trigger is in the CI pipeline (`.github/workflows/release.yml` or
  equivalent).
- The payload template is in a *central* repo (e.g., `org-ci-tools`),
  *not* duplicated across services.
- The OAuth client is registered against the tenant once; the secret is
  pushed to GitHub org-level secrets.

**Specific vs central:** Central, always. A per-service event hand-roll
is the single biggest source of "we have CI/CD observability but the
data is useless" you'll encounter.

---

### Q11. Is the Dynatrace GitHub Connector recommended?

**Yes for the Workflow → GitHub direction.** It removes the need for
custom Lambda / Azure Function relays when a Dynatrace Workflow needs
to act on a repo (open an issue, dispatch a workflow, set a commit
status). Setup is OAuth, scoped per workflow, no infra to operate.

**Use it when:**
- You want SRG verdicts to surface as GitHub commit statuses.
- You want Davis problems to auto-open GitHub issues with reproducer
  context.
- You want automated rollback to dispatch a `workflow_dispatch` event
  on a guarded branch.

**Don't use it as a replacement for:**
- Sending events *from* GitHub to Dynatrace — that's the reusable
  workflow / curl direction described in Q2/Q10.
- Webhook ingestion of pipeline events — that's the GitHub →
  OpenPipeline path in Q9.

**Dependencies:**
- A Dynatrace OAuth client.
- A GitHub App installed on the target org with the scopes your
  workflows actually use (least-privilege).

---

## Reference architecture for this repo

```
.devcontainer/
  util/my_functions.sh           # installGitlab, seedGitlabRepos,
                                 # deployLoadgenerator, installDtctl
  migrate/                       # staged assets (gitlab repos, loadgen)
  post-create.sh                 # deploys cluster, astroshop, gitlab,
                                 # seeds repos, installs dtctl
  post-start.sh                  # starts the load generator

dtctl/                           # NEW — declarative platform config
  dashboards/
    cicd-overview.yaml           # DORA + pipeline health
    release-comparison.yaml      # response time across releases
  slos/
    astroshop-availability.yaml
    astroshop-latency.yaml
    astroshop-error-rate.yaml
  guardians/                     # SRG definitions
    release-readiness.yaml       # blocks staging->prod promotion
    post-deploy-soak.yaml        # post-prod soak window
  workflows/
    on-deployment-event.yaml     # triggers guardian on CUSTOM_DEPLOYMENT
    post-deploy-rollback.yaml    # rollback via GitHub connector
  events/
    sample-deployment.yaml       # canonical deployment event payload

.github/workflows/
  dt-deployment-event.yml        # reusable workflow (Q2 pattern 1)
  release.yml                    # exercises the full flow

docs/
  cicd-observability.md          # this file
```

### What "running" looks like

1. `make start` → boots dev container, k3d cluster, OneAgent (CNFS).
2. `post-create.sh` → deploys Astroshop, installs GitLab in-cluster,
   seeds the 19 service repos + 3 support repos, installs `dtctl`,
   applies the `dtctl/` artifacts to the tenant.
3. `post-start.sh` → deploys the locust loadgen against the Astroshop
   ingress URL, generating traffic continuously.
4. Releases are flipped between `1.12.0/none`, `1.12.1/cpu`,
   `1.12.2/memory`, `1.12.3/n+1` either manually
   (`./scripts/flip-release.sh 1.12.1 cpu`) or hourly via the
   `start_load_generator` stage of the GitLab pipeline.
5. Each flip emits a `CUSTOM_DEPLOYMENT` event, which triggers the
   SRG via a Dynatrace Workflow, which writes a verdict back as a
   bizevent and (for the bad releases) opens a Davis problem.

---

## Workshop demo flow (60 min)

| Time | Topic | What to show |
|---|---|---|
| 0–5 | Setup overview | The repo layout, `make start` already running |
| 5–15 | Implicit vs explicit deployment events | Restart a pod → Davis sees it. Then fire `CUSTOM_DEPLOYMENT` and show the richer context in Problems |
| 15–25 | Release comparison via traces | Flip Astroshop to `1.12.1/cpu`, open the loadtest test step `04 - ad service`, compare with `1.12.0/none` in the Trace Comparison view |
| 25–35 | SRG in action | Trigger `release-readiness` guardian on the bad release, show FAIL verdict, walk through which SLO objectives broke |
| 35–45 | Rollback the bad release via Workflow | The post-deploy workflow detects FAIL, calls the GitHub Connector to dispatch the rollback workflow |
| 45–55 | Pipeline observability | GitHub workflow_run events in OpenPipeline → DORA dashboard |
| 55–60 | Q&A and "how do I take this home" | The reusable workflow pattern, dtctl skill for AI agents |

---

## Resources

- Pipeline observability with GitHub tutorial — `https://docs.dynatrace.com/docs/deliver/pipeline-observability-sdlc-events/tutorials/pipeline-observability-use-case-github`
- Deployment events v2 API — `https://docs.dynatrace.com/docs/dynatrace-api/environment-api/events-v2/post-event`
- Site Reliability Guardian — `https://docs.dynatrace.com/docs/deliver/site-reliability-guardian`
- Dynatrace GitHub Connector — `https://docs.dynatrace.com/docs/analyze-explore-automate/workflows/actions/github/github-workflows-setup`
- `dtctl` CLI — `https://github.com/dynatrace-oss/dtctl`
- Monitoring-as-Code (`monaco`) — `https://github.com/dynatrace/dynatrace-configuration-as-code`
- This repo's load test pattern — see `.devcontainer/migrate/astroshop_repos/loadgenerator/`
