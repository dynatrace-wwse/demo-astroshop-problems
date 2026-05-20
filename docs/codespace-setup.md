# Codespace setup — what users need to enter

This page covers the only thing a workshop attendee has to do before
starting: paste five values into the Codespace creation dialog.
After that, `post-create` runs the full bootstrap end-to-end —
Dynatrace operator, OneAgent injection, Astroshop, in-cluster GitLab,
22 seeded repos, dtctl, monaco config, request attributes, load test,
and the four release rolls. Total runtime ~20-25 minutes;
attendees can grab coffee.

---

## The five required secrets

These are declared in `.devcontainer/devcontainer.json` so Codespaces
prompts for them on creation (or pre-fills from your saved org
secrets):

| Secret | Format | What it's for |
|---|---|---|
| `DT_ENVIRONMENT` | `https://<id>.apps.dynatrace.com` | Platform UI URL. Sprint tenants use `https://<id>.sprint.apps.dynatracelabs.com`. |
| `DT_OPERATOR_TOKEN` | `dt0c01.…` | OneAgent install. Operator scopes: `ActiveGateTokenManagement`, `entities.read`, `settings.read`, `settings.write`, `DataExport`, `InstallerDownload`. |
| `DT_INGEST_TOKEN` | `dt0c01.…` | Runtime telemetry. Ingest scopes: `logs.ingest`, `metrics.ingest`, `openTelemetryTrace.ingest`. |
| `DT_API_TOKEN` | `dt0c01.…` | **The workshop token.** Scopes: `events.ingest`, `openpipeline.events_sdlc.custom`, `bizevents.ingest`, `ReadConfig`, `WriteConfig`, `CaptureRequestData`, `credentialVault.read`, `credentialVault.write`, `apiTokens.read`, `apiTokens.write`. |
| `DT_PLATFORM_TOKEN` | `dt0s16.…` | OAuth platform token for monaco + dtctl. Generate in **App settings → Platform tokens**. Scopes: `app-engine:apps:run`, `automation:workflows:read`, `automation:workflows:run`, `automation:workflows:write`, `document:documents:read`, `document:documents:write`, `settings:read`, `settings:write`. |

The first three (`DT_ENVIRONMENT`, `DT_OPERATOR_TOKEN`, `DT_INGEST_TOKEN`)
are enough to install OneAgent and get traces flowing. The last two
unlock monaco-as-code + the SRG workflow.

## Generating the tokens

In the Dynatrace UI:

1. **Access tokens** (top-right cog → Access tokens) — generate three
   tokens with the scope sets above. Name them so you can rotate them
   later: `astroshop-operator`, `astroshop-ingest`, `astroshop-workshop`.
2. **Platform tokens** (App settings → Platform tokens) — generate one
   token; name it `astroshop-platform`.

Paste the five values into Codespaces' "Set secret" dialog when you
create the Codespace. Codespaces stores them encrypted and injects
them as env vars in the container.

## What the bootstrap does, in order

`.devcontainer/post-create.sh` runs:

1. **Save the secrets** into `.devcontainer/.env` (gitignored, 0600)
   so the workshop helpers source them automatically.
2. **`bootstrapWorkshop`** (when all five secrets are present, outside
   CI):

   | Phase | Function | Time |
   |---|---|---|
   | Cluster | `startK3dCluster` | ~30 s |
   | Dynatrace operator + AppOnly | `dynatraceDeployOperator` + `deployApplicationMonitoring` | 1-2 min |
   | Astroshop | `deployApp astroshop` (15+ pods, OneAgent-injected) | 3-5 min |
   | GitLab | `installGitlab` (helm chart 9.4.0 in-cluster) | ~6 min |
   | Seed 22 repos | `seedGitlabRepos` | ~30 s |
   | dtctl + monaco | `installDtctl` + `installMonaco` + `applyMonacoConfig` | 1-2 min |
   | Vault credential | `createWorkshopCredentials` (creates `hot-session-token`) | <5 s |
   | Loadgen | `deployLoadgenerator` (locust + 12 SRG-aligned tasks) | ~30 s |
   | Roll 4 releases | `rollAstroshopRelease 1.12.{0,1,2,3} {none,cpu,memory,nplusone}` | ~6 min |

3. **`finalizePostCreation`** — framework's standard end-of-boot
   greeting with URLs and the next steps.

## After post-create — what's live

| Resource | Where |
|---|---|
| **Astroshop UI** | `printGreeting` shows the ingress URL (or `getAppURL astroshop`) |
| **GitLab UI** | `http://gitlab.<ip>.sslip.io` (user `root`, password printed by `installGitlab`) |
| **22 seeded GitLab projects** | `Otel-App/*` (19 services) + `Support/*` (3 support repos) |
| **Locust** | `astroshop-load` namespace, web UI `:8089` if you port-forward |
| **Dynatrace tenant** | SRG `Astroshop - Staging - Quality gate` + 2 workflows + 5 dashboards + 3 SLOs + ~120 platform configs |
| **Span data with `service.version` per release + `request_attribute.TSN/LTN/LSN`** | Continuous |

## One-time tenant-side steps (still UI)

Some Dynatrace settings need a click in the UI because the API requires
human consent:

| Step | Where | Why |
|---|---|---|
| **Authorization Settings** for the SRG workflow's actor | Settings → Authorization Settings → toggle the user from "needs consent" to "allowed" for automation tasks | The workflow runs *on behalf of* a user; that user must consent once. |
| **CI/CD Observability community app** "Import Configuration" | The app's Setup wizard (one click) | Installs OpenPipeline rules that translate our SDLC events into the app's expected shape. |
| **Workflow actor app-engine scope** *(optional, for the smoketest workflow)* | IAM → Policies → grant the user `app-engine:functions:run` + `app-engine:credential-vault:read` | Lets the smoketest workflow read credentials from the vault. |

Each is a one-click setup. After that, every workshop run is fully
automated from secrets only.

## Rotating the secrets

`DT_API_TOKEN` and `DT_PLATFORM_TOKEN` are the secrets you'd actually
need to rotate (the other three are framework-level). When you do:

1. Generate the replacement in the UI.
2. Update the Codespaces secret in **GitHub → Settings → Codespaces secrets**.
3. **Restart the Codespace** (the new value is only injected at boot).

Or pass them via `--env-file` for a local dev container:

```bash
cd .devcontainer
cp .env.example .env    # if needed
$EDITOR .env
make start
```
