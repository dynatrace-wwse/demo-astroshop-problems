--8<-- "snippets/4-content.js"

# Workshop content

## What's running after `post-create`

| Component | Where | Bootstrapped by |
|---|---|---|
| k3d cluster | dev container | framework `startK3dCluster` |
| Astroshop | `astroshop` namespace | `deployApp astroshop` |
| GitLab | `gitlab` namespace, ingress at `gitlab.<ip>.sslip.io` | `installGitlab` |
| 19 service repos + 3 support repos | inside GitLab | `seedGitlabRepos` |
| Locust loadgen | `astroshop-load` namespace | `deployLoadgenerator` (post-start) |
| dtctl CLI | `~/.local/bin/dtctl` | `installDtctl` |
| Dashboards / SLOs / Workflows | tenant | `applyDtctlConfigs` (manual) |

`printGreeting` shows the URLs for each.

## Accessing the Astroshop

Run `printGreeting` in the terminal — it lists the public URL on
`sslip.io`. In Codespaces it's `https://<codespace>-80.app.github.dev/`.

## Flipping the release / problem variant

The four release variants live on dedicated branches in the seeded
GitLab repos (`main`, `usecase/cpu`, `usecase/memory`, `usecase/n+1`,
`usecase/error`).

### Manual flip from the dev container

```bash
# Send the deployment event + SDLC pipeline event to Dynatrace
sendDeploymentEvent 1.12.1 staging cpu
```

### Manual flip via the Astroshop UI

The Astroshop also exposes its own feature-flag UI — open the URL from
the greeting and append `/feature`. In Codespaces this is something like
`https://<codespace>-80.app.github.dev/feature`.

![features flag](img/features_flag.png)

### Hourly auto-flip via the GitLab pipeline

The seeded `Support/Astroshop_Release` repo (`gitlab-ci.yml`) walks the
four releases on a schedule, emitting Workflow runs and CUSTOM_DEPLOYMENT
events at each stage — perfect for the unattended "let it run while we
talk" demo.

## Stop bad builds — the integrated demo

This is the meat of the workshop. See [Stop bad builds](stop-bad-builds.md)
for the full narrative; the short version:

1. Pipeline deploys `1.12.0` to staging → CUSTOM_DEPLOYMENT event fires.
2. Locust hammers the shop while OneAgent records traces + Golden Signals.
3. SRG validates the SLOs over the load-test window → PASS.
4. Pipeline promotes to production.
5. Repeat with `1.12.1`/cpu — SRG returns FAIL → pipeline **halts** before
   the `promote-production` job. The `Rollback astroshop` workflow can be
   dispatched from the Dynatrace Workflow via the GitHub Connector.

## CI/CD Observability — the Dynatrace app

This repo is wired to feed the
[community **CI/CD Observability** app](https://github.com/Dynatrace/community-examples/tree/main/dynatrace%20apps/CI-CD%20Pipeline).
The app is "available upon request" — your Dynatrace contact activates
it on your tenant, then the data path is:

```
GitHub Action / bash helper
    │  (POST)
    ▼
/platform/ingest/custom/events.sdlc/<provider>     ←  OpenPipeline rules
    │                                                 in the app translate
    ▼                                                 these to SDLC events
Grail (events table, kind=SDLC_EVENT)
    │
    ▼
CI/CD Observability app dashboards / flamegraph
```

The bash helper `seedCicdPipelineData` (see
`.devcontainer/util/my_functions.sh`) generates a four-release demo run
with all task events shaped exactly per the
[app's documented schema](https://github.com/Dynatrace/community-examples/tree/main/dynatrace%20apps/CI-CD%20Pipeline#-custom-events-format).

```bash
export DT_TENANT_URL=https://<tenant>.live.dynatrace.com
export DT_API_TOKEN=<token with openpipeline.events.ingest>
seedCicdPipelineData
```

## Resources cap & cleanup

The four broken-release pipelines deliberately stress the cluster. If a
codespace runs out of file descriptors:

```bash
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w fs.inotify.max_queued_events=16384
```

<div class="grid cards" markdown>
- [Stop bad builds :octicons-arrow-right-24:](stop-bad-builds.md)
- [Open questions Q&A :octicons-arrow-right-24:](cicd-observability.md)
- [Cleanup :octicons-arrow-right-24:](cleanup.md)
</div>
