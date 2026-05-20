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

`.github/workflows/release.yml` is the sample. A maintainer dispatches
it with `release_version: 1.12.1` and `problem: cpu`. The pipeline has
three jobs:

```
deploy-staging  →  validate (SRG gate)  →  promote-production
```

### Step 2 — Deployment event fires (the "marker") with PR + change context

Every job that touches an environment finishes with the reusable
composite action. The action enriches the deployment event with PR
metadata (number, title, author, files-changed, merge timestamp) and
the commit message, so any Davis problem raised after the deployment
shows **which PR caused it** right on the problem card — no diff
hunting required. See [PR and change details on Davis problem tickets](cicd-observability.md#pr-and-change-details-on-davis-problem-tickets)
for the full property list.

```yaml
- name: Notify Dynatrace — deployment event (staging)
  uses: ./.github/actions/dt-deployment-event
  with:
    dt_tenant_url:   ${{ secrets.DT_TENANT_URL }}
    dt_api_token:    ${{ secrets.DT_API_TOKEN }}
    application:     astroshop
    release_version: ${{ inputs.release_version }}
    release_stage:   staging
    problem:         ${{ inputs.problem }}
```

The action sends **two** things:

1. `POST /api/v2/events/ingest` — a `CUSTOM_DEPLOYMENT` event so Davis
   can correlate any problems against this release.
2. `POST /platform/ingest/custom/events.sdlc/github` — a
   pipeline-run SDLC event in the shape the **CI/CD Observability
   community app** expects.

Both calls are `continue-on-error: true` in spirit: observability never
blocks delivery.

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

```yaml
- name: Stop bad build
  if: steps.guardian.outputs.verdict != 'pass'
  run: |
    echo "::error::SRG verdict=fail — refusing to promote $VER to production"
    exit 1
```

The `promote-production` job has `if: needs.validate.outputs.verdict == 'pass'`,
so it never runs. The release is *visible everywhere* (CI/CD app, Davis
correlation, dashboards) but *cannot reach production*.

### Step 6 — Optional auto-rollback in production

If a release *does* make it to production and the post-deploy guardian
later fails, the Dynatrace Workflow
(`dtctl/workflows/on-deployment-event.yaml`) dispatches the
`Rollback astroshop` workflow via the GitHub Connector:

```yaml
rollback_on_fail:
  action: dynatrace.github.connector:dispatch-workflow
  input:
    repository: <org>/<repo>
    workflow: rollback.yml
    ref: main
    inputs:
      release_version: "{{ result('read_payload').release_version }}"
```

---

## Reproducing the demo without a Dynatrace tenant

The public release workflow uses a deterministic gate (`problem != none → fail`),
so even forks without Dynatrace credentials can show the blocking
behaviour in green/red:

```
gh workflow run release.yml -f release_version=1.12.1 -f problem=cpu
# → deploy-staging passes
# → validate fails on the "Stop bad build" step
# → promote-production is skipped
```

To run it *with* Dynatrace, set the two secrets in your repo / org:

| Secret | Value |
|---|---|
| `DT_TENANT_URL` | `https://<tenant-id>.live.dynatrace.com` |
| `DT_API_TOKEN` | API token with `events.ingest` + `openpipeline.events.ingest` |

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
