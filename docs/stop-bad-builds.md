# Stop bad builds before they hit production

The headline outcome of CI/CD observability with Dynatrace: a release
that *will* hurt production never gets there, because the pipeline asks
Dynatrace whether the candidate build behaved like a healthy release
under load, and refuses to promote if the answer is "no".

This page is the end-to-end narrative. The Q&A in
[cicd-observability.md](cicd-observability.md) covers individual
questions in detail.

---

## The pipeline we showcase: in-cluster GitLab

The workshop drives the **in-cluster GitLab** seeded by `installGitlab`
+ `seedGitlabRepos`. The pipeline that walks the four release variants
lives in `Support/Astroshop_Automated_Load_test`; the platform
configuration that gates promotion is owned by
`Support/Dynatrace_Monitoring_as_Code` via **monaco**. GitHub Actions
artefacts in `.github/` are a parallel demo of the same loop for teams
on GitHub.

| # | Part | Where it lives |
|---|---|---|
| 1 | Pipeline emits CUSTOM_DEPLOYMENT + SDLC events, `event.provider=gitlab` | bash helpers `sendDeploymentEvent` / `sendPipelineEvent` / `sendTaskEvent` called from GitLab CI |
| 2 | Locust drives load with `LTN=Astroshop` baggage | `.devcontainer/migrate/astroshop_repos/loadgenerator/` |
| 3 | SRG `Astroshop - Staging - Quality gate` (11 test-step latency objectives) | **monaco** — `init_configs/labs/srg-staging.json` |
| 4 | Workflow runs the guardian per deployment, opens GitLab issue on FAIL | **monaco** — `init_configs/labs/srg-workflow.json` + `gitlab-connection.json` |
| 5 | Verdict bizevent (`event.category="guardian"`) — `pass` for 1.12.0, `fail` for 1.12.1/2/3 | `runDeploymentValidation` (or the SRG workflow on a live tenant) |
| 6 | Pipeline halts staging→prod when verdict ≠ pass | `Otel-App/<svc>/.gitlab-ci.yml` orchestrated by `Support/Astroshop_Release` |
| 7 | (Optional) PR lifecycle events for the CI/CD Observability app | `.github/workflows/pr-events.yml` (GitHub) — equivalent GitLab hook calls `sendPipelineEvent` |

---

## The narrative

### Step 1 — Pipeline runs

The GitLab project `Support/Astroshop_Automated_Load_test` walks the
four release variants in a single pipeline; for each variant the
trigger fires `.gitlab.release-ci.yml` in `Otel-App/<service>`. Three
logical stages:

```
deploy-staging  →  validate (SRG gate)  →  promote-production
```

A maintainer who wants to demo one variant directly can also run
`seedWorkshopReleases` from the dev container — it fires the same
event sequence in seconds, without provisioning the GitLab runner.

### Step 2 — Deployment event fires (the "marker") with MR + change context

Each GitLab job that touches an environment sources `my_functions.sh`
and calls `sendDeploymentEvent`. The helper enriches the
`CUSTOM_DEPLOYMENT` payload with `git.commit.*`, `Repository`,
`Release_Stage`, `PROBLEM`, and any merge-request context it can
resolve (`pr.number`, `pr.url`, `pr.title`, `pr.author`), so any
Davis problem raised after the deployment shows **which MR caused
it** right on the problem card — no diff hunting required. See
[PR and change details on Davis problem tickets](cicd-observability.md#pr-and-change-details-on-davis-problem-tickets)
for the full property list.

```yaml
# .gitlab-ci.yml fragment
notify-deploy:
  stage: deploy-staging
  script:
    - source .devcontainer/util/my_functions.sh
    - sendDeploymentEvent $VERSION staging $PROBLEM
    - sendPipelineEvent astroshop-release $CI_PIPELINE_ID \
        "Astroshop release pipeline" success \
        $CI_COMMIT_REF_NAME $CI_PROJECT_PATH $GITLAB_USER_LOGIN 240
  allow_failure: true   # observability never blocks delivery
```

The helpers send **two** things:

1. `POST /api/v2/events/ingest` — a `CUSTOM_DEPLOYMENT` event so Davis
   can correlate any problems against this release.
2. `POST /platform/ingest/custom/events.sdlc/gitlab` — pipeline + task
   SDLC events in the shape the **CI/CD Observability community app**
   expects.

GitHub equivalent (`.github/actions/dt-deployment-event/`) is one
`uses:` line; same payload shape.

### Step 3 — Load drives the SLO window

The locust generator deployed in `astroshop-load` is already hitting
the frontend, generating end-to-end traces with `loadtest=true` and
`teststep=<name>` baggage on every request. That gives the SLOs a
statistically meaningful sample size, so the SRG verdict isn't noise.

### Step 4 — SRG verifies the SLOs

The `validate` stage of the GitLab pipeline triggers the
`Astroshop - Staging - Quality gate` guardian (defined in monaco at
`init_configs/labs/srg-staging.json`) over the load-test window. The
guardian has **11 DQL-based test-step latency objectives** — one per
load test step:

```
01 - homepage              06 - get recommendations
02 - get products          07 - get cart in B
03 - get currencies        08 - empty cart
04 - ad service            09 - add product B
05 - add product A         10 - get cart in A
                           11 - checkout
```

Each objective: `LESS_THAN_OR_EQUAL` 1000 ms target, 900 ms warning,
median over the load-test window. The bad-build variants (cpu, memory,
n+1) deliberately push the relevant test step over the target.

For the *public* workflow (this repo, no tenant attached), the gate is
deterministic — it fails on every non-`none` `problem` input so the
blocking behaviour is reproducible without a tenant.

### Step 5 — The pipeline halts

In the GitLab pipeline:

```yaml
validate:
  stage: gate
  script:
    - test "$(runDeploymentValidation $VERSION staging $PROBLEM)" = "pass"
  # If runDeploymentValidation prints anything other than 'pass', the
  # job fails and the dependent promote stage is skipped.

promote-production:
  stage: deploy-prod
  needs: [validate]
  when: on_success   # only runs if validate passed
```

The promote stage never runs. The release is *visible everywhere*
(CI/CD app, Davis correlation, dashboards) but *cannot reach
production*.

The GitHub Actions equivalent in `.github/workflows/release.yml` uses
`if: needs.validate.outputs.verdict == 'pass'` for the same effect.

### Step 6 — Optional auto-rollback in production

If a release *does* make it to production and the post-deploy guardian
later fails, the Dynatrace Workflow (`labs/srg-workflow.json` in
monaco) uses the **GitLab Connector** to open a GitLab issue OR
dispatch a rollback pipeline on the previous good tag. The same
workflow can call the **GitHub Connector** instead — only the action
type changes:

```yaml
# In the monaco-defined workflow
rollback_on_fail:
  action: dynatrace.gitlab.connector:gitlab-issue-create   # or
          # dynatrace.github.connector:dispatch-workflow
  input:
    connection: "{{ .gitlab_connection_id }}"
    projectId: 3
    title: "Rollback astroshop {{ event()['deploymentVersion'] }}"
    description: "SRG verdict failed — rolling back."
```

---

## Reproducing the demo without provisioning the GitLab pipeline

If you don't want to wait for the full `bootstrapWorkshop`, the bash
helpers in this repo replay the same event sequence directly to your
tenant:

```bash
# tokens + URL are in .devcontainer/.env (gitignored, 0600)
set -a; source .devcontainer/.env; set +a
source .devcontainer/util/source_framework.sh
seedWorkshopReleases
# → 4 CUSTOM_DEPLOYMENT + 4 pipeline runs + 24 task events + 4 SRG verdicts
#   1.12.0 = pass, 1.12.1/2/3 = fail
```

To replay against your *own* tenant (instead of COE), set these in
`.devcontainer/.env`:

| Var | Value |
|---|---|
| `DT_TENANT_URL` | `https://<tenant-id>.live.dynatrace.com` |
| `DT_API_TOKEN` | API token with `events.ingest` + `openpipeline.events_sdlc.custom` |
| `DT_PLATFORM_TOKEN` | OAuth platform token (`dt0s16…`) — needed by monaco / dtctl |

---

## Why this matters (the elevator pitch)

Most teams already have *some* deployment marker in Dynatrace — a pod
restart, a process-group version label. That gets you correlation. It
doesn't get you **prevention**.

This repo wires the *prevention loop*: the same pipeline that delivers
the change asks the platform if the change is safe, and the platform
answers based on *real telemetry from a real load test* — not from a
spreadsheet, a synthetic check on a quiet environment, or a static rule.

That's the difference between "we'll find out at 3 AM" and "we knew
before the merge button was even clickable".
