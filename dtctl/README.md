# dtctl/ — Dynatrace platform as code

This directory holds declarative Dynatrace platform configuration applied
with [`dtctl`](https://github.com/dynatrace-oss/dtctl). The dev container
installs `dtctl` automatically (`installDtctl` in
`.devcontainer/util/my_functions.sh`).

## Layout

```
dtctl/
  dashboards/      # dashboards & notebooks  (dtctl apply -f *.yaml)
  slos/            # SLO definitions          (dtctl apply -f *.yaml)
  guardians/       # Site Reliability Guardians (see notes)
  workflows/       # Dynatrace Workflows      (dtctl apply -f *.yaml)
  events/          # canonical event payloads (deployment, test boundaries)
```

## How to apply

```bash
# one-time setup of the dev container
dtctl auth login --context demo \
  --environment "https://<tenant-id>.apps.dynatrace.com"

# apply everything
applyDtctlConfigs              # bash helper from my_functions.sh
# or individually
dtctl apply -f dashboards/cicd-overview.yaml
dtctl apply -f slos/astroshop-availability.yaml
```

## Notes on guardians (SRG)

`dtctl` ships native support for dashboards, SLOs, workflows, and
settings. Site Reliability Guardian resources are managed today through
either:

1. The Dynatrace Workflow that runs the guardian
   (`dtctl apply -f workflows/on-deployment-event.yaml`), or
2. The Settings 2.0 schema for guardians
   (`dtctl get settings --schema dynatrace.srg:guardians`).

Files under `guardians/` are kept as documentation of intent; the
workflow under `workflows/on-deployment-event.yaml` does the actual
execution.
