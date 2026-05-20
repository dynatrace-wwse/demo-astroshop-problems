--8<-- "snippets/index.js"

--8<-- "snippets/disclaimer.md"

# Astroshop CI/CD Observability — stop bad builds before they hit production

A self-contained, public-shareable workshop that shows how to use Dynatrace
to **see every release** and **block the ones that will hurt production**.

The repo boots a Codespace (or local Docker dev container), spins up:

- a k3d Kubernetes cluster with **Astroshop** (OpenTelemetry demo),
- a self-hosted **GitLab** with 19 service repos + 3 support repos,
- a **locust + Playwright** load generator continuously driving the shop,
- the Dynatrace **dtctl** CLI for managing dashboards / SLOs / workflows
  as code,

then walks through emitting `CUSTOM_DEPLOYMENT` events, ingesting pipeline
events into the **Dynatrace CI/CD Observability app**, gating promotion
with a **Site Reliability Guardian**, and auto-rolling-back via the
**GitHub Connector**.

## Why this exists

Customers ask the same handful of questions every time:

- *"Do I have to send CUSTOM_DEPLOYMENT events manually, or is it automated?"*
- *"How do we keep this scalable across 100s of repos?"*
- *"Is Snyk the only path for security signals?"*
- *"How do I block a production deployment in GitHub Actions when the SLO fails?"*

The [CI/CD Observability Q&A](cicd-observability.md) answers them with
runnable examples from this repo. The [Stop bad builds](stop-bad-builds.md)
page is the end-to-end narrative tying it all together.

## Bad releases shipped in this repo

The Astroshop has four deliberately broken releases. Flip between them
to demo Davis correlation, trace comparison, SRG verdicts, and rollback.

| Version | Problem | What you see |
|---|---|---|
| `1.12.0` | `none` | baseline, SRG passes |
| `1.12.1` | `cpu` | empty-loop CPU spike in `AdService.computeAds()` |
| `1.12.2` | `memory` | retained `byte[]` array in `GarbageCollectionTrigger` |
| `1.12.3` | `nplusone` | repeated DB calls per cart item |

!!! tip "What will we do"
    Provision the full stack with two commands, then watch the same
    pipeline that delivers `1.12.0` *block* `1.12.1` thanks to SLO-based
    quality gates.

<p align="center">
  <img src="img/dt_professors.png" alt="Workshop" width="180">
</p>

<div class="grid cards" markdown>
- [Yes! let's begin :octicons-arrow-right-24:](2-getting-started.md)
</div>
