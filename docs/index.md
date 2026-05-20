--8<-- "snippets/index.js"

--8<-- "snippets/disclaimer.md"

# Astroshop CI/CD Observability — stop bad builds before they hit production

A self-contained, public-shareable workshop that shows how to use Dynatrace
to **see every release** and **block the ones that will hurt production**.

The repo boots a Codespace (or local Docker dev container) and, with
one bash call (`bootstrapWorkshop`), brings up:

- a k3d Kubernetes cluster with **Astroshop** (OpenTelemetry demo),
- a self-hosted **in-cluster GitLab** with 19 service repos + 3 support
  repos — the pipeline we showcase,
- a **locust + Playwright** load generator continuously driving the shop,
- the Dynatrace **monaco** CLI applying SRG + workflows + dashboards
  + tagging rules from `Support/Dynatrace_Monitoring_as_Code` to your
  tenant,
- the Dynatrace **dtctl** CLI for kubectl-style day-to-day ops.

The end-to-end story: the GitLab pipeline that walks the four
Astroshop release variants emits `CUSTOM_DEPLOYMENT` + pipeline-run +
task events; the **Site Reliability Guardian** (`Astroshop - Staging
- Quality gate`, 11 test-step latency objectives) evaluates each one
over the load-test window; the bad-build variants are blocked from
promotion to production, and the SRG-driving workflow opens a GitLab
issue via the **Dynatrace GitLab Connector**.

Equivalent **GitHub Actions** artefacts live under `.github/` so teams
on GitHub get the same loop with one file change.

## Reading order

| If you want… | Start here |
|---|---|
| The mental model — what speaks to what, which token, which endpoint | [How it all connects](architecture.md) |
| The narrative — pipeline run, SRG fails, build blocked | [Stop bad builds](stop-bad-builds.md) |
| To rebuild this for your own app + CI | [Apply to your app](apply-to-your-app.md) |
| Answers to the 11 questions customers always ask | [Open questions Q&A](cicd-observability.md) |
| Every Dynatrace resource the workshop deploys | [Monaco config](monaco-config.md) |

## Bad releases shipped in this repo

The Astroshop has four deliberately broken releases. Flip between them
to demo Davis correlation, trace comparison, SRG verdicts, and rollback.

| Version | Problem | What you see |
|---|---|---|
| `1.12.0` | `none` | baseline, SRG passes |
| `1.12.1` | `cpu` | empty-loop CPU spike in `AdService.computeAds()` |
| `1.12.2` | `memory` | retained `byte[]` array in `GarbageCollectionTrigger` |
| `1.12.3` | `nplusone` | repeated DB calls per cart item |

!!! tip "What we will do"
    Provision the full stack with `bootstrapWorkshop`, then watch the
    same GitLab pipeline that delivers `1.12.0` *block* `1.12.1`
    thanks to the SRG. `seedWorkshopReleases` produces the demo data
    in seconds for a 1-pass + 3-fail story your tenant shows
    immediately.

<p align="center">
  <img src="img/dt_professors.png" alt="Workshop" width="180">
</p>

<div class="grid cards" markdown>
- [Yes! let's begin :octicons-arrow-right-24:](2-getting-started.md)
</div>
