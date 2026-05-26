
# Workshop labs — ace-box order

After [bootstrapWorkshop](codespace-setup.md) finishes, the cluster
+ tenant are ready. This page walks through the eight labs from the
original HOT2025 deck in order. Each one builds on the previous.

If you came straight here, the [stop-bad-builds](stop-bad-builds.md)
narrative is the elevator pitch; this page is the **labs**.

---

## Lab 1 — Diagnostic tools: traces on Grail

**Goal.** Get comfortable with the Traces app and DQL so you can find
what you're looking for under load.

1. Open the Services app (Ctrl+K → *services*).
2. Filter to services in the `astroshop` namespace.
3. Add the column **Last seen**.
4. Save the result as a DQL notebook called `Lab 1`.
5. Filter requests for `astroshop-cartservice` (or your closest match
   — `cart` in the migrated repo) with response time > 100 ms.
6. Group failing services by endpoint.

**Where the data comes from:** OneAgent (AppOnly) is injected on every
astroshop entrypoint pod. Spans land in Grail with `service.name` +
`request_attribute.TSN` populated by the [monaco request-attribute
rules](monaco-config.md#labs--the-workshop-deliverables).

---

## Lab 2 — Developer feedback with the Live Debugger

**Goal.** Find an issue end-to-end without rebuilding: code-level
debug data without redeployment.

The loadgen drives the Astroshop continuously, so problems are always
on. Reproduce in three steps:

1. Open the Distributed Traces app and find a failed request with the
   trailing `x-dynatrace-test` header (filter by `request_attribute.TSN`).
2. Open the Live Debugger (Ctrl+K → *debug*).
3. Set a non-breaking breakpoint on the responsible line; collect
   variable values without changing the code.

In the original ace-box workshop you can debug via the **Omnichannel
satellite** scripts (`satellite_addToCart`, `satellite_checkout`).
That's optional here — the loadgen already produces the symptom.

---

## Lab 3 — Intelligent release evaluations (the SRG)

**Goal.** See how the **Site Reliability Guardian** scores a release.

The bootstrap rolled all four release variants. Each has a guardian
evaluation that you can re-run:

```bash
# from the dev container
rollAstroshopRelease 1.12.1 cpu     # rolls + triggers the SRG workflow
```

The SRG in monaco is `Astroshop - Staging - Quality gate` with **20
objectives**:

- 12 DQL-based **test-step latency** objectives (one per load-test
  step), threshold ≤ 1000 ms median, warn at 900 ms.
- 4 infrastructure: CPU throttling, CPU Max, Max Memory in MB,
  Failed requests.
- 4 traffic / quality: Total Traces and Spans, Total amount Load Test
  Requests, Sum of 5XX requests, Logs with errors.

All 20 queries verified to return data on a properly bootstrapped
COE-style tenant.

---

## Lab 4 — Foundations of load test analysis

**Goal.** Find one load test run in Grail; compare steps across
releases.

1. Use Traces on Grail to find all traces in the last 6 hours where
   `request_attribute.LTN` contains "Astroshop".
2. Group by `request_attribute.TSN` — each group is one of the 12
   test steps.
3. Open a trace from `04 - ad service ` (the trailing space is real
   and intentional in the SRG DQL).
4. Compare p95 latency across the four release variants
   (`service.version` is now per release thanks to
   `rollAstroshopRelease`).

---

## Lab 5 — Release comparison: response time decrease (1.12.1)

**Goal.** Find *why* 1.12.1 failed the SRG.

The SRG verdict points at the **ad-service** step exceeding the
1000 ms target. Drill in:

1. Open Trace Comparison — filter both sides by the same TSN
   (`04 - ad service `).
2. Compare 1.12.1 vs 1.12.0 by `service.version`.
3. Look at the slowest method in the call tree. The CPU spike is in
   `AdService.computeAds()` — empty loops added on purpose. Source:
   `tmp/perform-…/lab-guide/` references it explicitly.

---

## Lab 6 — Release comparison: garbage collection (1.12.2)

**Goal.** Find the GC-driven memory blow-up on 1.12.2.

1. Compare 1.12.2 with 1.12.0 in trace comparison.
2. The ad service is now 504ing on a 15s timeout, but the underlying
   span runs for several minutes — that's GC suspension time.
3. Open Profiling & Optimization for the ad PG. Survived memory
   peaks at ~3 GB; main responsible class is the
   `GarbageCollectionTrigger` holding a 1.23 GB `byte[]`.

---

## Lab 7 — Runtime optimization: CPU analysis

**Goal.** Identify which release is the most CPU-intensive and why.

1. Open Profiling & Optimization.
2. Filter by `k8s.namespace.name == "astroshop"`.
3. Find the PG (ad service) with highest consumption; split by
   `service.version`.
4. Drill into method hotspots — `computeAds()` is the culprit on
   1.12.1.

---

## Lab 8 — Runtime optimization: memory analysis

**Goal.** Quantify the GC impact, find the leak.

1. Notebook → explore metrics → **Garbage Collection time**.
2. Filter by `k8s.namespace.name == "astroshop"`, split by PG.
3. On the high-suspension PG, open Technologies & Processes.
4. From the PGI, navigate to the flame graph → memory survived
   objects → the `TransactionMemoryLeak` (1.12.3 use case).

---

## Bringing the workshop up

| Component | Where | Bootstrapped by |
|---|---|---|
| k3d cluster | dev container | framework `startK3dCluster` |
| Dynatrace operator + AppOnly | dynatrace ns | `dynatraceDeployOperator` + `deployApplicationMonitoring` |
| Astroshop | `astroshop` ns | `deployApp astroshop` (OneAgent-injected) |
| In-cluster GitLab | `gitlab` ns, `gitlab.<ip>.sslip.io` | `installGitlab` |
| 22 seeded repos | inside GitLab | `seedGitlabRepos` |
| Locust loadgen | `astroshop-load` ns | `deployLoadgenerator` |
| SRG + workflows + dashboards + tagging | tenant | `applyMonacoConfig` (269+ resources) |
| Vault credential `hot-session-token` | tenant | `createWorkshopCredentials` |
| Four releases rolled (1.12.0/1/2/3) | astroshop deployments + Davis events | `rollAstroshopRelease` × 4 |

All of that happens automatically from `bootstrapWorkshop` when the
five Codespace secrets are present (see [Codespace setup](codespace-setup.md)).

## Accessing the Astroshop

`printGreeting` in the terminal lists the public URL on `sslip.io`
(or `https://<codespace>-80.app.github.dev/` in Codespaces).

## Flipping the release / problem variant

```bash
# Roll one variant (patches pod labels, sets service.version,
# restarts pods, fires CUSTOM_DEPLOYMENT + bizevent that triggers
# the SRG workflow)
rollAstroshopRelease 1.12.1 cpu

# Replay all four
seedWorkshopReleases
```

The four release variants live on dedicated branches in the seeded
GitLab repos (`main`, `usecase/cpu`, `usecase/memory`, `usecase/n+1`,
`usecase/error`).

Hourly auto-flip works the same way — the seeded
`Support/Astroshop_Automated_Load_test` repo's pipeline walks the
four versions on a schedule.

<div class="grid cards" markdown>
- [Stop bad builds :octicons-arrow-right-24:](stop-bad-builds.md)
- [Open questions Q&A :octicons-arrow-right-24:](cicd-observability.md)
- [Cleanup :octicons-arrow-right-24:](cleanup.md)
</div>
