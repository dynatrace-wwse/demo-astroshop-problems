# Apply this workshop to your app

This page is the recipe. The Astroshop demo is one instance of a
pattern that drops into any application + any CI system. Seven steps;
expect a half-day of work for a single service, a sprint for an
organisation-wide rollout.

The whole story is in [How it all connects](architecture.md); this
page is the *to-do list* version.

---

## Decisions to make first (15 minutes)

| Decision | Default | Why |
|---|---|---|
| **Which app(s) first?** | The one with the worst recent change-failure-rate | Highest leverage — the team feels the pain |
| **Which environment is the gate?** | Staging | Production gates are riskier; nail staging first |
| **Test-step model** | One SLO objective per critical user journey step | Mirrors what users actually do; matches what Astroshop ships |
| **CI system** | Your existing one (GitLab/GitHub/Jenkins/ADO) | Don't introduce a new CI as part of this |
| **Source of truth for platform config** | monaco | Versioned, peer-reviewable, replayable |

---

## Step 1 — Make the application observable

You need code-level traces with **test-step context** so the SRG has
something to compare across releases.

**What this repo does:** OneAgent is installed via the Dynatrace
Operator on the k3d cluster. Request attributes `LTN` (load-test
name) and `TSN` (test-step name) are configured in monaco
([`monaco/init_configs/request-attributes/`](https://github.com/dynatrace-wwse/demo-astroshop-problems/tree/main/.devcontainer/migrate/support_repos/dynatrace_env_automation/monaco/init_configs/request-attributes))
to capture the W3C baggage headers the loadgen propagates.

**What you do for your app:**

1. Install OneAgent (or otel collector → Dynatrace) on the workloads.
2. Pick **5–15 user journeys** that matter. For an e-commerce shop:
   homepage, browse products, add to cart, checkout. For an API:
   the top-N endpoints by traffic + the top-N by business value.
3. Inject a request attribute per step. Two options:
   - Your load test sends `traceparent` + `baggage: teststep=<n>`
     and Dynatrace captures the baggage as a request attribute
     ([this is what we do](https://github.com/dynatrace-wwse/demo-astroshop-problems/blob/main/.devcontainer/migrate/astroshop_repos/loadgenerator/locustfile.py)).
   - Or a server-side header your gateway sets — same idea.

**You're done with this step when:** Distributed Traces in Dynatrace
shows the test-step name as a column or filter.

---

## Step 2 — Make a load test that produces those traces

Without sustained, repeatable traffic, the SLO percentiles oscillate
and the SRG verdict is noise.

**What this repo does:** A locust + Playwright generator in
`astroshop-load` namespace exercises the entire purchase flow in a
headless browser, propagating baggage on every request.

**What you do:**

1. Pick a load test tool you already use (locust, k6, JMeter, Gatling).
2. Make sure it propagates W3C trace-context + baggage. Most of them
   support this with a one-line config now.
3. Run it continuously against staging — even at low volume — so the
   SLO window is always full of signal. Spin it up to high volume
   only when you're gating a release.

**You're done with this step when:** the test-step request attribute
populates for 100% of traffic during a load-test window.

---

## Step 3 — Define the SLOs that matter

This is the part that needs *judgement*, not tooling.

**What this repo does:** 11 DQL-based latency objectives in
[`monaco/init_configs/labs/srg-staging.json`](https://github.com/dynatrace-wwse/demo-astroshop-problems/tree/main/.devcontainer/migrate/support_repos/dynatrace_env_automation/monaco/init_configs/labs/srg-staging.json),
one per test step. Target: median ≤ 1000 ms, warning at 900 ms.

**Three SLO categories to cover:**

| Category | Example DQL pattern | Why |
|---|---|---|
| **Latency** (per step) | `median(duration)` filtered by `request_attribute.TSN` | The thing users feel |
| **Errors** (overall + per step) | `1 - sum(failure_count) / sum(count)` | Catches regressions that show as 5xx, not slowness |
| **Saturation** (resource-level) | `avg(container.cpu.usage)` or `avg(container.memory.usage)` | Early warning before latency/errors degrade |

**Anti-patterns to avoid:**

- Static averages instead of percentiles (`avg(duration)` is useless
  on noisy traffic; use `percentile(duration, 95)`).
- Counters instead of ratios for errors. `error_count > 100` fails on
  a quiet weekend.
- Targets defined as "this week minus 5%". That's a ratchet that
  passes once and fails forever.

**You're done with this step when:** Your SLOs report a stable
percentage against a representative load test.

---

## Step 4 — Create the SRG with monaco

The SRG is just *a collection of SLOs* with a target threshold for
each. Define it as code; apply with monaco.

**What this repo does:** the
[`labs/srg-staging.json`](https://github.com/dynatrace-wwse/demo-astroshop-problems/tree/main/.devcontainer/migrate/support_repos/dynatrace_env_automation/monaco/init_configs/labs/srg-staging.json)
schema is `app:dynatrace.site.reliability.guardian:guardians`. The
file is referenced from `labs/config.yaml` and applied by
`monaco deploy manifest.yml`.

**What you do:**

1. Copy the file as a starter. Edit the `objectives` array — each
   item is `{ name, objectiveType: DQL, dqlQuery, target, warning, comparisonOperator }`.
2. Add the file to your monaco project under
   `init_configs/<your-folder>/`.
3. Reference it from `config.yaml` with schema
   `app:dynatrace.site.reliability.guardian:guardians`.
4. Apply: `monaco deploy manifest.yml`.

**You're done with this step when:** The SRG appears in the Dynatrace
UI and you can run it manually with a custom time range.

---

## Step 5 — Wire the CI pipeline

Two events from the CI side. Bash helpers cover both.

**What this repo does:**

```bash
# .gitlab-ci.yml or any CI script:
source .devcontainer/util/my_functions.sh

# 1) the release marker — for Davis correlation + dashboards
sendDeploymentEvent $VERSION staging $PROBLEM

# 2) pipeline-run + task events — for the CI/CD Observability app
sendPipelineEvent $PIPELINE_ID $RUN_ID "$PIPELINE_NAME" $OUTCOME \
                  $BRANCH $REPO $USER $DURATION
sendTaskEvent     $TASK_ID    "build" success $PIPELINE_ID $RUN_ID …
```

GitHub equivalent — one `uses:` of
`.github/actions/dt-deployment-event/` per environment job.

**What you do:**

1. Source the helpers (or copy them into your CI tools repo).
2. Set the env vars in your CI's secrets/variables:
   - `DT_TENANT_URL=https://<id>.live.dynatrace.com`
   - `DT_API_TOKEN=<token with events.ingest + openpipeline.events_sdlc.custom>`
3. Add a job at the end of every environment-touching stage that
   calls the helpers.

**You're done with this step when:** A DQL of
`fetch events, from: -1h | filter event.provider == "<your-ci>"`
returns rows after a pipeline run.

---

## Step 6 — Run the guardian on every deployment

Two patterns; pick one.

### Pattern A — pipeline-triggered (pull)

The CI job that just deployed waits a soak period, then runs the SRG
via `dtctl` and reads the verdict:

```bash
EXEC_ID=$(dtctl exec workflow $SRG_WF_ID -o json | jq -r .id)
until [ "$(dtctl get wfe $EXEC_ID -o json | jq -r .state)" != "RUNNING" ]; do sleep 10; done
VERDICT=$(dtctl get wfe $EXEC_ID -o json | jq -r .verdict)
test "$VERDICT" = "pass"
```

Pros: simple, all in one pipeline.
Cons: pipeline runner sits idle during soak.

### Pattern B — Dynatrace-triggered (push)

A Dynatrace Workflow listens for `CUSTOM_DEPLOYMENT` events, runs
the guardian after a soak window, and posts the verdict back via the
GitLab / GitHub Connector (commit status, issue, or dispatched
pipeline). The CI promote-job waits on that status.

**This repo ships pattern B** —
[`labs/srg-workflow.json`](https://github.com/dynatrace-wwse/demo-astroshop-problems/tree/main/.devcontainer/migrate/support_repos/dynatrace_env_automation/monaco/init_configs/labs/srg-workflow.json).

Pros: no idle runner; richer side-effects (auto-rollback, ticket
creation).
Cons: more moving parts.

**You're done with this step when:** a deployment event reliably
triggers the SRG and produces a verdict you can act on.

---

## Step 7 — Block the promote stage on the verdict

This is the "stop bad builds" part. Boring on purpose.

```yaml
# GitLab
validate:
  stage: gate
  script:
    - test "$(runDeploymentValidation $VERSION staging $PROBLEM)" = "pass"

promote-production:
  stage: deploy-prod
  needs: [validate]
  when: on_success
```

```yaml
# GitHub Actions
validate:
  needs: deploy-staging
  outputs: { verdict: ${{ steps.guardian.outputs.verdict }} }
promote:
  needs: validate
  if: needs.validate.outputs.verdict == 'pass'
```

**Roll-out order — least scary first:**

1. **Audit only.** Emit verdicts but don't block. Run for a week.
2. **Warn on fail.** Mark the build red but allow promotion.
3. **Block on fail.** Refuse to promote.
4. **Auto-rollback.** The workflow dispatches the rollback pipeline.

Most teams stop at 3 for a year before turning on 4. That's fine.

---

## Cheat-sheet — what to install where

| Where | Install |
|---|---|
| Workloads | OneAgent or OTel collector → Dynatrace |
| Anywhere CI runs | Bash helpers from this repo's `my_functions.sh` *or* the GitHub composite action *or* the GitLab include |
| Workshop driver (laptop / dev box) | monaco (config-as-code), dtctl (interactive ops) |
| Dynatrace tenant | Activate the community CI/CD Observability app (one Setup Wizard click) so it consumes your SDLC events |

## Recipe-applied checklist

- [ ] OneAgent (or OTel) on the target workloads
- [ ] Test-step request attributes captured (`TSN`, `LTN` or your names)
- [ ] Load test sends baggage + runs continuously in staging
- [ ] 5–15 SLOs covering latency / errors / saturation
- [ ] SRG defined in monaco with those SLOs as objectives
- [ ] CI pipeline calls `sendDeploymentEvent` + `sendPipelineEvent`
- [ ] Verdict workflow exists (push) **or** CI polls dtctl (pull)
- [ ] Promote stage gated `when: on_success` / `if: verdict == pass`
- [ ] (Optional) Auto-rollback workflow wired via GitLab/GitHub Connector
- [ ] Notification template shows PR/MR fields on Davis problem cards

---

## What this looks like in production

The four classes of dashboards / apps you'll end up using:

- **Davis problem cards** — for the on-call. Show "which MR caused
  this" inline.
- **DORA dashboard** (one tile per metric) — for leadership.
  Deployment frequency, lead time, change failure rate, MTTR.
- **CI/CD Observability community app** — for the platform team.
  Pipeline durations, queue depth, job retries.
- **The SRG verdict timeline** — for the dev team. Shows the
  history of pass/fail by service, release version.

Each one consumes the same three signals (deployment events, SDLC
events, runtime traces) — just sliced differently.
