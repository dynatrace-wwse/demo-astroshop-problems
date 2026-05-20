# guardians/ — Site Reliability Guardian (SRG)

> **The workshop's actual SRG lives in monaco**, not here. See
> [`../../.devcontainer/migrate/support_repos/dynatrace_env_automation/monaco/init_configs/labs/srg-staging.json`](../../.devcontainer/migrate/support_repos/dynatrace_env_automation/monaco/init_configs/labs/srg-staging.json)
> for `Astroshop - Staging - Quality gate` with 11 test-step latency
> objectives (homepage, get products, get currencies, ad service,
> add product A/B, get recommendations, get cart in B/A, empty cart,
> checkout). Schema:
> `app:dynatrace.site.reliability.guardian:guardians`.
> It is applied by monaco when the `Support/Dynatrace_Monitoring_as_Code`
> GitLab pipeline runs (see `init_configs/labs/config.yaml`).

`dtctl` (today) does not have a dedicated `kind: guardian` resource.
SRG is managed through two paths in this repo:

1. **Execution-time:** the workflow under
   [`../workflows/on-deployment-event.yaml`](../workflows/on-deployment-event.yaml)
   calls `dynatrace.site.reliability.guardian:validate-guardian-action`
   with `guardianIdentifier: release-readiness`. The guardian definition
   itself is created once in the tenant UI or via the Settings 2.0
   schema.

2. **Configuration-as-code (Settings 2.0):**
   ```bash
   # export an existing guardian
   dtctl get settings --schema dynatrace.srg:guardians -o yaml > release-readiness.yaml

   # version it under this folder, then apply on a new tenant
   dtctl apply settings -f release-readiness.yaml
   ```

## Recommended guardian objectives for the Astroshop demo

Tied to the SLOs under `../slos/`:

| Objective | Source SLO | Pass threshold | Warn threshold |
|---|---|---|---|
| Service availability | `astroshop-availability` | ≥ 99% | ≥ 99.5% |
| Ad-service p95 latency | `astroshop-latency` | ≥ 95% of window | ≥ 98% |
| Overall error rate | `astroshop-error-rate` | ≥ 98% | ≥ 99% |
| New critical CVEs from Snyk | `count() == 0` | == 0 | == 0 |

The guardian is *configured* once. The workflow *executes* it on every
deployment.

## Two production-friendly guardian patterns

### Release readiness (pre-promotion)
- Triggered by: `CUSTOM_DEPLOYMENT` in staging.
- Evaluation window: load test start → load test end.
- On FAIL: pipeline halts promotion to production.

### Post-deploy soak (post-promotion)
- Triggered by: `CUSTOM_DEPLOYMENT` in production.
- Evaluation window: deploy_ts → deploy_ts + 10 min.
- On FAIL: dispatch `rollback.yml` GitHub workflow via the GitHub
  Connector.
