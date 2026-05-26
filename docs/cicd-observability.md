# CI/CD Observability with Dynatrace — Workshop Q&A

This document is a self-contained workshop reference. The pipeline it
showcases is the **GitLab pipeline** that lives in the in-cluster GitLab
seeded by this repo (`Support/Astroshop_Automated_Load_test` walks the
four broken release variants of the Astroshop). The platform config that
makes the SRG fail bad builds lives in **monaco** under
[`Support/Dynatrace_Monitoring_as_Code`](../.devcontainer/migrate/support_repos/dynatrace_env_automation/monaco/).
Wherever a customer specifically asks about GitHub, the answer includes
the equivalent GitHub Actions snippet — but everything works on both.

No customer-specific data appears in this file.

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

Four outcomes are repeatable across customers, and they map to the DORA
metrics SREs are usually asked to report on:

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
2. **Pipeline execution signals** — workflow and job-level events
   ingested via job hooks (GitLab/Jenkins/ADO/GitHub) into Dynatrace
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
|  (GitLab/GitHub)  |          |     platform        |         |  (k8s, hosts, apps)  |
+-------------------+          +---------------------+         +----------------------+
        |                                |                                |
        | 1. CUSTOM_DEPLOYMENT event     |                                |
        |------------------------------->| Events v2                      |
        |                                |                                |
        | 2. job/workflow webhooks       |                                |
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
signals.

### Developer

| Question | Where the answer lives | Signal needed |
|---|---|---|
| "Is my MR/PR safe to merge?" | SRG verdict on the merge-request pipeline | SLOs over the load-test window; pipeline-run SDLC event with `vcs.ref.head.name` |
| "Did my deploy cause this problem?" | Davis problem card → linked deployment event | `CUSTOM_DEPLOYMENT` with `git.commit.*` + `Repository` properties |
| "Which line of code did this?" | Trace → method-hotspots → permalink to git blame | OneAgent code-level traces + git commit on the deployment event |
| "How long is my CI taking compared to last week?" | Pipeline Observability app, filter by author | Pipeline + task SDLC events with `ext.pipeline.run.trigger.user` |
| "Are any of my tests flaky?" | Pipeline app, filter by `task.outcome == failed` over time | Task SDLC events with `task.retry` |

### CI/CD SRE / Platform engineer

| Question | Where | Signal |
|---|---|---|
| DORA four keys per team | DORA dashboard | Deployment + SDLC events with `deploymentProject` |
| Pipeline duration / queue depth | Pipeline Observability app | Pipeline + task SDLC events with `start_time` / `end_time` |
| Change Failure Rate by service | DQL on deployment events joined with Davis problems within N minutes | CUSTOM_DEPLOYMENT + Davis problems |
| Which release introduces the most regressions? | DQL on `srg.verdict == "fail"` grouped by `deploymentProject` | SRG verdict events |
| Is our pipeline observability *itself* healthy? | DQL: count of pipeline events ingested vs expected | SDLC ingest health |

### Engineering lead

| Question | Where | Signal |
|---|---|---|
| Are we shipping faster or slower this quarter? | DORA dashboard, 90-day trend | All of the above, aggregated |
| Which teams are blocked at the gate? | SRG verdict timeline | SRG verdict events + service ownership tag |
| Are we adding risk faster than we burn it down? | Vulnerabilities trend vs deployment rate | Snyk / native scan events alongside deployment events |
| How fast do we recover when things go wrong? | MTTR tile of the CI/CD overview dashboard | `recovery_timestamp - deployment timestamp` for linked problems |

The trick for the engineering-lead view: keep it to **four to six tiles
at most**. Anything more and they stop opening it.

---

## PR and change details on Davis problem tickets

The single highest-leverage thing you can do for the on-call experience
is to make sure the Davis problem card answers "which change caused
this?" right at the top.

### What lands on the problem card today (out of the box)

Davis already correlates each problem against deployments in the
affected entity's history. The card shows:

- Deployment timestamp + name (from `CUSTOM_DEPLOYMENT`)
- Linked entity (the service whose health changed)
- "Affected releases" list

That gets you *that a deployment happened around the time of the
problem*. It doesn't yet tell you *which MR/commit introduced it*.

### What you add with this repo's helpers

The bash function `sendDeploymentEvent` (in
[`.devcontainer/util/my_functions.sh`](../.devcontainer/util/my_functions.sh))
and the GitHub composite action
[`.github/actions/dt-deployment-event/`](../.github/actions/dt-deployment-event/action.yml)
both enrich the `CUSTOM_DEPLOYMENT` payload with the same properties so
your GitLab pipeline and a GitHub workflow produce the same problem-card
shape:

| Property | Source (GitLab CI) | Source (GitHub Actions) | Why it matters |
|---|---|---|---|
| `git.commit.id` | `$CI_COMMIT_SHA` | `${{ github.sha }}` | Permalink to the diff |
| `git.commit.branch` | `$CI_COMMIT_REF_NAME` | `${{ github.ref_name }}` | Branch context |
| `git.commit.message` | `$CI_COMMIT_MESSAGE` | `git log -1 --pretty=%s` | First-line summary |
| `Repository` | `$CI_PROJECT_URL` | `${{ github.repository }}` | Which repo |
| `ciBackLink` | `$CI_JOB_URL` | run URL | Pipeline link |
| `pr.number` / `pr.url` / `pr.title` / `pr.author` | `$CI_MERGE_REQUEST_*` vars | `github.event.pull_request.*` | The PR/MR that introduced the change |
| `change.ticket` | passed-in arg | passed-in arg | Jira/ServiceNow ID |

These are indexed in Grail; DQL queries can group problems by author,
file count, or change ticket.

### How the on-call experience changes

**Before**:
> Problem P-1234 on `astroshop-adservice`. Deployment "astroshop release 1.12.1" 8 min ago.

**After**:
> Problem P-1234 on `astroshop-adservice`.
> Deployment "astroshop release 1.12.1 — MR !34".
> MR !34: *"switch to async ad cache"* by `alice@`, 5 files changed.
> [Open MR](http://gitlab.<ip>.sslip.io/Otel-App/adservice/-/merge_requests/34)
> · [Diff](http://gitlab.<ip>.sslip.io/Otel-App/adservice/-/commit/abc1234)
> Change ticket: `CHG-1142`.

That's the difference between "page on-call awake to investigate" and
"page on-call with the link to the MR already in their notification".

### Tenant-side configuration to surface these on the problem card

1. **Notification template** — add `{ProblemEvents}` placeholder in the
   Slack / Teams / email problem notification so the PR fields show.
2. **OpenPipeline rule** — optional: enrich the deployment event by
   joining against the latest change ticket if you don't fire it from
   the pipeline.
3. **Davis problem comments via Workflow** — the SRG workflow in monaco
   (`labs/srg-workflow.json`) can post MR metadata as a problem comment
   when a problem opens within N minutes of a deployment.

---

## The 11 open questions and their answers

### Q1. Is the link between deployments and production problems purely dependent on manually sending `CUSTOM_DEPLOYMENT` events through the Events API? Or is there an automated mechanism in the SDLC pipelines that creates deployment markers automatically?

**Short answer:** Both exist, and you almost always want both layers.

1. **Automatic correlation, no events required.** Dynatrace already
   knows when a process or container restarts, when an image tag
   changes on a pod, and when an Azure App Service revision flips.
   Davis treats these as implicit deployment boundaries and correlates
   problems against them. No code, no API, no events. This is your floor.
2. **Explicit `CUSTOM_DEPLOYMENT` events.** Layered on top, you send
   one event per "logical release" so Davis (and your dashboards) can
   group pods that came from the same pipeline run, attribute a problem
   to a specific commit, and reason at the granularity *you* care about.

**Why you want both:** The implicit layer is free and catches
everything, including hotfixes done outside the pipeline. The explicit
layer adds *business context* (pipeline URL, commit, ticket ID, change
ticket, release version) that Davis surfaces in the Problems UI and
that you can query in DQL.

**Reference in this repo (GitLab — the one we demo):**
`Support/Astroshop_Automated_Load_test/scripts/event.sh` is the GitLab
CI script that triggers a Dynatrace Automation workflow with the
deployment context. The repo also exposes the bash helper
[`sendDeploymentEvent`](../.devcontainer/util/my_functions.sh) so any
GitLab job can do `sendDeploymentEvent 1.12.1 staging cpu` to mark a
release.

**Also in GitHub Actions:** the equivalent composite action
[`.github/actions/dt-deployment-event/`](../.github/actions/dt-deployment-event/action.yml)
fires the same payload — usable from any GitHub workflow with a
two-line `uses:` block.

---

### Q2. How do we send `CUSTOM_DEPLOYMENT` events? Do we configure this globally or per repository? How do we reduce developer overhead?

**Short answer:** Centralize the implementation, distribute via a
reusable include — developers add one line.

**Three implementation patterns, ranked by how well they scale:**

1. **(Recommended) Reusable CI include / shared action.** Build it
   once, call it from every repo.

   **GitLab CI** (what this repo uses):

   ```yaml
   # In every service repo, a single include:
   include:
     - project: 'Support/Astroshop_Automated_Load_test'
       file: '/templates/notify-deploy.yml'

   notify-deploy:
     extends: .dynatrace-deploy-event
     variables:
       APP: astroshop
       STAGE: production
   ```

   **GitHub Actions** (equivalent):

   ```yaml
   jobs:
     notify-deploy:
       uses: my-org/.github/.github/workflows/dt-deployment-event.yml@v1
       with:
         application: ${{ github.event.repository.name }}
         release_stage: production
   ```

   Developers don't see Dynatrace at all — secrets, payload shape,
   retry logic, and field naming all live in the central template.

2. **Pipeline-side helper script.** A bash/PowerShell helper that
   wraps the `POST /api/v2/events` call. Lives in a shared `ci-tools`
   repo and is sourced into each pipeline. This repo ships exactly
   that — `sendDeploymentEvent` in `my_functions.sh` is the helper
   GitLab CI calls. Simpler to ship than a reusable include but the
   API surface is exposed to the repo.

3. **Per-repo bespoke script.** Avoid. Drift is guaranteed within
   months.

**Field-naming convention we recommend** (matches what this repo emits):

| Property | Source | Example |
|---|---|---|
| `event.type` | hard-coded | `CUSTOM_DEPLOYMENT` |
| `deploymentName` | pipeline | `astroshop release 1.12.1` |
| `deploymentVersion` | git tag / build var | `1.12.1` |
| `deploymentProject` | repo name | `astroshop` |
| `ciBackLink` | pipeline URL | `${CI_JOB_URL}` |
| `Release_Stage` | env name | `staging` / `production` |
| `git.commit.id` | `${CI_COMMIT_SHA}` | `abc123…` |
| `git.commit.branch` | `${CI_COMMIT_REF_NAME}` | `usecase/cpu` |

Searchable in Grail with DQL such as:

```dql
fetch events, from:now() - 24h
| filter event.kind == "DEPLOYMENT_EVENT" and deploymentProject == "astroshop"
| sort timestamp desc
```

**Authentication:** prefer an OAuth client (`dt0s16…`) for the platform
endpoints, and an `events.ingest`-scoped Api-Token (`dt0c01…`) for
`/api/v2/events/ingest`. Scope tightly; rotate via your secrets manager.

**PoC plan inside this repo:**
1. `installMonaco` + `applyMonacoConfig` push the SRG and the
   SRG-driving workflow to the tenant.
2. `seedWorkshopReleases` fires the four release variants
   (`1.12.0/none → 1.12.1/cpu → 1.12.2/memory → 1.12.3/nplusone`) so
   the tenant has a 1-pass-3-fail story in seconds.

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
the ActiveGate, not from your tenant. The group lets you scope which
AG talks to Snyk (e.g., dedicated security AGs in a hardened zone).

**How it reaches OpenPipeline:** the Snyk extension writes events into
the built-in `security.events` ingest endpoint
(`/platform/ingest/v1/security.events`). From there, OpenPipeline is
*the* place you reshape, enrich, route, or fan-out those events — for
example, joining them with the deployment event so a build that
introduced a critical CVE is tagged "risky" before it reaches
production.

**Recommendation:** Build CI-pushed findings *and* the Snyk extension
in parallel. They complement each other:
- CI-push = real-time risk at build time. GitLab CI can call
  `snyk test --json | curl … security.events` in any `test:` job.
- Snyk extension = backstop / scheduled reconciliation, catches drift.

---

### Q4. Does the ingestion source itself determine how data is normalized for CI/CD observability?

**Short answer:** Yes — pick the *purpose-built* endpoint for each
signal so the platform applies the right schema, and don't fan
everything through one generic ingest URL.

| Signal | Endpoint | Result table / kind |
|---|---|---|
| Deployment | `POST /api/v2/events/ingest` (event.type=CUSTOM_DEPLOYMENT) | `dt.davis.events`, kind=DEPLOYMENT_EVENT |
| Pipeline run / job | `POST /platform/ingest/custom/events.sdlc/<provider>` | `events`, kind=SDLC_EVENT |
| Security finding | `POST /platform/ingest/v1/security.events` | `security.events` |
| Logs (general) | OTLP / log ingest | `logs` |
| Custom business event | `POST /api/v2/bizevents/ingest` | `bizevents` |

Each endpoint owns: schema validation, default attribute extraction,
default retention, and which apps surface it. Misroute a deployment as
a plain log and you lose the auto-correlation with Davis problems;
misroute a security finding as a deployment event and the Security
Investigator app won't see it.

**OpenPipeline** can rewrite/route data *after* ingestion, but it can't
recover schema fields you didn't send.

**Rule of thumb:** signal type → endpoint → schema. OpenPipeline is for
enrichment and routing, not for fixing sloppy ingestion.

**For this repo:** `sendDeploymentEvent` posts to
`/api/v2/events/ingest`; `sendPipelineEvent` and `sendTaskEvent` post
to `/platform/ingest/custom/events.sdlc/gitlab` (the path the community
CI/CD Observability app's OpenPipeline rules pick up).

---

### Q5. Are there guidelines / best practices for designing the GitHub Actions (or GitLab CI jobs) that fire these events? Naming conventions, when to fire, etc.?

**Short answer:** Yes — the conventions are the same regardless of CI
vendor.

**When to fire:**

- **Deployment event:** the moment the artifact lands in the target
  environment — *after* the rollout has reported success, *before* you
  start post-deploy validation. Firing too early (e.g., on job start)
  creates phantom deployments if the job is cancelled.
- **Start-of-test event:** when synthetic / load tests start. Lets
  you bound the SRG analysis window.
- **End-of-test event:** when they complete. SRG uses this as the
  `to` timestamp.
- **Promotion / rollback events:** the *human-meaningful* moments,
  not the technical ones.

**Naming conventions:**

- GitLab job names: `dt:<action>` (e.g., `dt:deployment-event`)
- GitHub workflow file names: `dt-<action>.yml`
- Action / job inputs: `lower_snake_case` (`application`,
  `release_version`, `git_commit_sha`)
- Event property keys: `dot.notation` matching OTel conventions where
  they exist (`git.commit.id`, `service.name`, `deployment.environment`)
- Version strings: SemVer if you can; otherwise build IDs that sort
  lexicographically

**Defensive design:**

- Always provide a fallback for `ciBackLink` so you never lose the
  link between an event and the pipeline that fired it.
- `allow_failure: true` (GitLab) / `continue-on-error: true` (GitHub)
  for the Dynatrace step. The deploy succeeds even if Dynatrace ingest
  is briefly unavailable — observability should never block delivery.
- Retry with exponential backoff (3 attempts, jitter).
- Emit one event per *logical release*, not one per service in a
  monorepo, unless services release independently.

**Two action implementations to consider** (GitHub specifically):

1. **Composite action that wraps curl** — simplest, no Docker, runs
   on any runner. This repo's
   [`.github/actions/dt-deployment-event/`](../.github/actions/dt-deployment-event/action.yml)
   is exactly that.
2. **Docker action that wraps `dtctl`** — richer (can read existing
   workflows, do diff/apply), but ties you to runners that can run
   Docker.

---

### Q6. To use SRG (SLO-based quality gates) properly, what do we depend on — synthetic monitor, continuous testing, etc.?

**Short answer:** SRG is a function of SLOs, and SLOs need *signal*.
Without signal, SRG passes everything because every guardian is "OK by
default". Three categories of signal feed it:

1. **Runtime signal (free).** OneAgent on the workloads gets you the
   four Golden Signals automatically. Use this to gate releases
   against the environment's behavior.
2. **Load test signal.** Sustained, repeatable traffic so latency
   percentiles converge. Without this, an SRG that gates on p95 will
   be noisy because a quiet environment has small samples. **This
   repo ships a locust-based generator** under
   `.devcontainer/migrate/astroshop_repos/loadgenerator/` that
   exercises Astroshop's purchase flow with `WebsiteBrowserUser`
   (Playwright headless), producing realistic end-to-end traces.
3. **Synthetic signal.** HTTP and full-browser checks that verify the
   app is *available* and that critical user journeys work. The repo
   has a synthetic monitor in monaco (`init_configs/synthetic-monitor/`)
   that the SRG can use as an availability SLI.

**Optional but high-value:**

- **Business / KPI signal.** A conversion-rate or revenue SLI lets
  SRG reason about user impact, not just technical health.
- **Quality / security signal.** Snyk/CodeQL findings as SLI inputs
  (e.g., "zero new criticals" must be ≤ 0).

**Anti-patterns to avoid:**

- Gating on raw counters (`error_count`) instead of ratios (`error_rate`).
- Using averages instead of percentiles for latency.
- Defining the SLO target as "this week's value minus 5%" — that's a
  ratchet that always passes the *first* time and never the second.

**In this repo:** the SRG `Astroshop - Staging - Quality gate` in
`monaco/init_configs/labs/srg-staging.json` defines **11 DQL
test-step latency objectives** (homepage, get products, get
currencies, ad service, add product A, get recommendations, get cart
in B, empty cart, add product B, get cart in A, checkout). Each
target: median ≤ 1000 ms, warning at 900 ms. The bad release
variants deliberately blow through these.

---

### Q7. We want to block a production pipeline based on an SRG evaluation that ran post-staging deployment. How do we do that in GitLab CI (or GitHub Actions)? What does it depend on?

**Two integration patterns. Pick one per team.**

#### Pattern A — pipeline polls Dynatrace (pull)

**GitLab CI** (what this repo uses):

```yaml
validate:
  stage: gate
  script:
    - export ID=$(dtctl exec workflow $SRG_WORKFLOW_ID -o json | jq -r .id)
    - |
      until [ "$(dtctl get execution $ID -o json | jq -r .state)" != "RUNNING" ]; do
        sleep 10
      done
    - test "$(dtctl get execution $ID -o json | jq -r .verdict)" = "pass"

promote:
  stage: deploy-prod
  needs: ["validate"]
  when: on_success
```

If `validate` fails, `promote` never runs.

**GitHub Actions** (equivalent):

```yaml
validate:
  needs: deploy-staging
  outputs:
    verdict: ${{ steps.guardian.outputs.verdict }}
  steps:
    - id: guardian
      run: |
        # same dtctl trigger + poll pattern
        echo "verdict=$(dtctl get execution $ID -o json | jq -r .verdict)" >> "$GITHUB_OUTPUT"

promote:
  needs: validate
  if: needs.validate.outputs.verdict == 'pass'
```

#### Pattern B — Dynatrace Workflow calls back into the SCM (push)

The Dynatrace Workflow runs the guardian and uses the **GitLab
Connector** (already in monaco at `labs/gitlab-connection.json`) to
post a commit status or trigger a downstream pipeline. The
`promote` job in GitLab waits on that status check. Same idea with
the GitHub Connector for GitHub.

#### Dependencies (either pattern)

- An SLO definition (`monaco/init_configs/labs/...` or
  `dtctl/slos/*.yaml`).
- An SRG that references the SLO objectives
  (`monaco/init_configs/labs/srg-staging.json`).
- A *signal source* — load test or synthetic — that runs *between*
  the start-test and end-test events.
- A `START_TEST` / `END_TEST` event pair so the guardian's time
  window is well-defined (see the bash `sendPipelineEvent` helper).
- An OAuth platform token (`dt0s16…`, scope
  `automation:workflows:run`) for the workflow path.

This repo ships both patterns in `monaco/init_configs/labs/` —
`srg-workflow.json` is the Workflow + GitLab Connector callback.

---

### Q8. Flow: post-prod deployment → execute SRG on SLOs → trigger rollback. What are the dependencies?

Same building blocks as Q7 plus a rollback hook. The end-to-end loop:

```
deploy(prod)
  └─> CUSTOM_DEPLOYMENT event (Release_Stage=production)
       └─> Dynatrace Workflow trigger "deployment in prod"
            ├─> wait for soak window (10–30 min)
            ├─> evaluate guardian (SLOs over the soak window)
            ├─> if FAIL:
            │     ├─> create Davis problem (severity=ERROR_EVENT)
            │     ├─> notify on-call (Slack/PagerDuty action)
            │     └─> trigger rollback action:
            │          - GitLab Connector → run pipeline on the previous
            │            successful release tag
            │          - or `kubectl rollout undo deployment/...`
            │            from a controlled runner
            └─> if PASS: emit "promoted" event and close the loop
```

**Dependencies:**

- SLOs already exist.
- A *previous good version* is identifiable. Easiest: the
  `CUSTOM_DEPLOYMENT` payload from the previous successful release
  lives in Grail; the Workflow queries for the last `result=PASS`.
- The rollback action is idempotent and safe to call from
  automation. This is the part teams usually *don't* have — they
  have to build the inverse of their deploy job. Build it once;
  treat it as a peer of deploy.
- OAuth scopes for `automation:workflows:run`, `events.ingest`, and
  whatever the rollback connector needs.

**Risk to flag:** automated rollback on a regression the SLO
*incorrectly* believes is real (e.g., a quiet-traffic false negative)
can be more disruptive than the regression. Start with rollback
gated on human approval, promote to fully automated only once the
SLOs have demonstrated low false-positive rates over multiple cycles.

This repo's `srg-workflow.json` (in monaco) opens a GitLab issue
rather than auto-rolling back; flipping it to "dispatch a rollback
pipeline" is one task change.

---

### Q9. Is the GitHub pipeline-observability tutorial the recommended path?

**For GitLab** (the pipeline we showcase) the answer is "use the
GitLab equivalent": the GitLab webhook → OpenPipeline path with
`event.provider=gitlab`. The
[community CI/CD Observability app](https://github.com/Dynatrace/community-examples/tree/main/dynatrace%20apps/CI-CD%20Pipeline)
supports GitLab, GitHub Actions, and Azure DevOps natively — install
the app on the tenant, run its setup wizard, point your GitLab CI at
the resulting webhook URL.

This repo gives you everything to wire it up:
- `sendPipelineEvent` and `sendTaskEvent` in bash produce events
  shaped to the app's documented schema.
- `seedWorkshopReleases` posts 4 pipeline runs × 6 tasks + verdicts
  with `event.provider=gitlab`, so the app populates immediately.
- The GitLab CI in the seeded `Otel-App/loadgenerator` calls these
  helpers from real pipeline runs.

**For GitHub** — yes, the
[official tutorial](https://docs.dynatrace.com/docs/deliver/pipeline-observability-sdlc-events/tutorials/pipeline-observability-use-case-github)
is the right path: `workflow_run` + `workflow_job` webhooks land in
OpenPipeline as SDLC events.

**Caveats (both):**

- Webhooks need a publicly reachable endpoint. Either send directly
  to `*.live.dynatrace.com` or front via an ActiveGate / reverse
  proxy.
- The default schema is good but provider-specific —
  cross-tool aggregation (GitHub + GitLab + Jenkins) needs a
  normalization layer in OpenPipeline.

**Recommendation:** use the provider-specific path as your baseline,
then design an OpenPipeline rule that normalizes pipeline events from
*any* CI system to a single schema (`ci.system`, `ci.pipeline.id`,
`ci.run.id`, `ci.job.id`, `ci.outcome`, `ci.duration`). Dashboards
then work regardless of CI vendor.

---

### Q10. For the Events API, what's the recommended approach (curl / PowerShell / cmd)? Who configures it, and where? Specific use case only, or central?

**Recommended approach, in priority order:**

1. **A reusable CI include / shared action**. GitLab CI `include:` or
   GitHub `uses:` — declarative, reviewable, secrets at org level.
2. **A shared bash helper**. `sendDeploymentEvent` in this repo is
   that helper — sourced into any pipeline via the framework. Same
   shape works in GitLab CI, Jenkins, Azure Pipelines, GitHub
   Actions. Pure curl under the hood.
3. **`dtctl apply -f event.yaml`** — when you want a declarative
   record of the event. Useful for AI agents and reproducible labs.
4. **Raw curl** — fine as a fallback, but you re-implement retry,
   auth refresh, and payload validation yourself.

PowerShell or `cmd.exe` are last-resort options used only because a
Windows-only build agent has nothing else. They work, but you'll
re-write them when you migrate runners.

**Who configures it:**

- **Platform / Observability team** owns the central reusable
  include, the OAuth client, the secret, and the payload schema.
- **Service teams** consume it by calling the include with a couple
  of inputs (`application`, `environment`). They never touch the
  API directly.

**Where it's done in the code:**

- The trigger is in the CI pipeline (`.gitlab-ci.yml` /
  `.github/workflows/release.yml` / equivalent).
- The payload template is in a *central* repo (this repo's
  `Support/Astroshop_Automated_Load_test` plays that role for
  GitLab), *not* duplicated across services.
- The OAuth client is registered against the tenant once; the secret
  is pushed to GitLab CI variables / GitHub org secrets.

**Specific vs central:** Central, always. A per-service event
hand-roll is the single biggest source of "we have CI/CD
observability but the data is useless".

---

### Q11. Is the Dynatrace GitHub Connector recommended?

For **GitHub**: yes — for the Workflow → GitHub direction. It removes
the need for custom Lambda / Azure Function relays when a Dynatrace
Workflow needs to act on a repo (open an issue, dispatch a workflow,
set a commit status). Setup is OAuth, scoped per workflow, no infra
to operate.

**Use it when:**

- You want SRG verdicts to surface as GitHub commit statuses.
- You want Davis problems to auto-open GitHub issues with reproducer
  context.
- You want automated rollback to dispatch a `workflow_dispatch` on a
  guarded branch.

For **GitLab** — and this is what this repo demos — the equivalent is
the **Dynatrace GitLab Connector**, also OAuth-scoped, also wired in
monaco under
[`labs/gitlab-connection.json`](../.devcontainer/migrate/support_repos/dynatrace_env_automation/monaco/init_configs/labs/gitlab-connection.json).
The SRG workflow (`labs/srg-workflow.json`) uses it to **open a GitLab
issue when the guardian fails** — same idea as the GitHub case.

**Don't use either as a replacement for:**

- Sending events *from* SCM to Dynatrace — that's the reusable
  include / curl direction (Q2, Q10).
- Webhook ingestion of pipeline events — that's the SCM →
  OpenPipeline path (Q9).

**Dependencies:**

- A Dynatrace OAuth client (platform token `dt0s16…`).
- A GitHub App / GitLab token with the scopes your workflows
  actually use (least-privilege).

---

## Reference architecture for this repo

```
.devcontainer/
  util/my_functions.sh           # installMonaco, applyMonacoConfig,
                                 # installGitlab, seedGitlabRepos,
                                 # deployLoadgenerator, installDtctl,
                                 # sendDeploymentEvent, sendPipelineEvent,
                                 # seedWorkshopReleases, bootstrapWorkshop
  migrate/                       # staged GitLab repos (pushed on bootstrap)
    support_repos/
      dynatrace_env_automation/
        monaco/                  # SOURCE OF TRUTH for platform config
          manifest.yml
          init_configs/
            labs/                # SRG + SRG workflow + GitLab connector
            document-dashboard/  # Astroshop loadtest overview, etc
            builtin*/            # tagging, span attributes, request attrs
            …
    astroshop_repos/             # 19 service repos including loadgenerator
  post-create.sh                 # bootstraps the cluster + dev tooling
  post-start.sh                  # info banner; loadgen lives in bootstrap

dtctl/                           # parallel demo of platform config in dtctl
  dashboards/   slos/   workflows/   events/   guardians/

.github/                         # GitHub Actions mirror of the GitLab loop
  actions/dt-deployment-event/   # composite action used by release.yml
  workflows/release.yml + rollback.yml + pr-events.yml

docs/
  index.md
  4-content.md
  stop-bad-builds.md             # end-to-end narrative
  cicd-observability.md          # this file
  monaco-config.md               # full inventory of monaco resources
```

### What "running" looks like

1. `make start` → boots dev container, k3d cluster.
2. `bootstrapWorkshop` (one bash call) →
   - `deployApp astroshop` (15+ pods)
   - `installGitlab` (helm) + `seedGitlabRepos` (push 22 repos)
   - `installDtctl` + `installMonaco` + `applyMonacoConfig`
     (SRG, workflows, dashboards, tagging applied to tenant)
   - `deployLoadgenerator` (locust + Playwright)
3. `seedWorkshopReleases` → 4 deployments + 4 pipeline runs + 24 task
   events + 4 SRG verdicts to the tenant; 1 pass + 3 fail.
4. Browse the result on the tenant: CI/CD Observability app,
   `Astroshop loadtest overview` dashboard, problems on
   `astroshop-adservice`.

---

## Workshop demo flow (60 min)

| Time | Topic | What to show |
|---|---|---|
| 0–5 | Setup overview | Repo layout, `bootstrapWorkshop` already done, COE tenant has SRG + dashboards |
| 5–15 | Implicit vs explicit deployment events | Restart a pod → Davis sees it. Then `sendDeploymentEvent` and show the richer context with `git.commit.*` |
| 15–25 | Release comparison via traces | Flip Astroshop to `1.12.1/cpu`, open the loadtest test step `04 - ad service`, compare with `1.12.0/none` in the Trace Comparison view |
| 25–35 | SRG in action | Trigger the `Astroshop - Staging - Quality gate` guardian on the bad release, show FAIL verdict, walk through which test-step objective broke |
| 35–45 | Rollback the bad release via Workflow | The post-deploy workflow detects FAIL, calls the GitLab Connector to open a GitLab issue (or dispatch a rollback pipeline) |
| 45–55 | Pipeline observability | GitLab pipeline events in OpenPipeline → DORA dashboard, Pipeline Observability app |
| 55–60 | Q&A | The reusable include pattern, dtctl skill for AI agents |

---

## Resources

- Community CI/CD Observability app — <https://github.com/Dynatrace/community-examples/tree/main/dynatrace%20apps/CI-CD%20Pipeline>
- Pipeline observability tutorial (GitHub) — <https://docs.dynatrace.com/docs/deliver/pipeline-observability-sdlc-events/tutorials/pipeline-observability-use-case-github>
- Deployment events v2 API — <https://docs.dynatrace.com/docs/dynatrace-api/environment-api/events-v2/post-event>
- Site Reliability Guardian — <https://docs.dynatrace.com/docs/deliver/site-reliability-guardian>
- Dynatrace GitHub Connector — <https://docs.dynatrace.com/docs/analyze-explore-automate/workflows/actions/github/github-workflows-setup>
- `dtctl` CLI — <https://github.com/dynatrace-oss/dtctl>
- Monitoring-as-Code (monaco) — <https://github.com/Dynatrace/dynatrace-configuration-as-code>
- This repo's monaco config — [docs/monaco-config.md](monaco-config.md)
- This repo's load test pattern — `.devcontainer/migrate/astroshop_repos/loadgenerator/`
