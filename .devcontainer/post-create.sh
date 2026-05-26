#!/bin/bash
# Codespace post-create — boots the dev tooling, then (if the user
# supplied all the workshop secrets) brings up the full workshop
# end-to-end. The 5 Codespace secrets are declared in devcontainer.json;
# users set them once when creating the Codespace.
#
# Required secrets for the *full* automated bootstrap:
#   DT_ENVIRONMENT         platform URL  https://<id>.apps.dynatrace.com
#   DT_OPERATOR_TOKEN      OneAgent install token (operator/ingest scopes)
#   DT_INGEST_TOKEN        traces/metrics/logs ingest
#   DT_API_TOKEN           ReadConfig + WriteConfig + events.ingest +
#                          openpipeline.events_sdlc.custom + bizevents.ingest +
#                          CaptureRequestData + credentialVault.{read,write} +
#                          apiTokens.{read,write}
#   DT_PLATFORM_TOKEN      dt0s16… OAuth platform token (monaco + dtctl)
#
# With only DT_ENVIRONMENT + DT_OPERATOR_TOKEN + DT_INGEST_TOKEN the
# dev container is still usable for the framework labs; `bootstrapWorkshop`
# can be invoked later from the terminal.

export SECONDS=0
source .devcontainer/util/source_framework.sh

setUpTerminal

startK3dCluster

installK9s

# Mirror the Codespace secrets into .devcontainer/.env so the workshop
# helpers source them automatically. .env is mode 0600 + gitignored.
if [ -n "$DT_API_TOKEN" ] || [ -n "$DT_PLATFORM_TOKEN" ]; then
  printInfoSection "Persisting Codespace secrets to .devcontainer/.env"
  cat > .devcontainer/.env <<ENVEOF
DT_ENVIRONMENT=${DT_ENVIRONMENT}
DT_OPERATOR_TOKEN=${DT_OPERATOR_TOKEN}
DT_INGEST_TOKEN=${DT_INGEST_TOKEN}
DT_API_TOKEN=${DT_API_TOKEN}
DT_BIZEVENTS_TOKEN=${DT_API_TOKEN}
DT_PLATFORM_TOKEN=${DT_PLATFORM_TOKEN}
DT_TENANT_URL=${DT_ENVIRONMENT//.apps./.live.}
ENVEOF
  chmod 600 .devcontainer/.env
  printInfo "Secrets stored. \`source .devcontainer/.env\` to pick them up."
fi

# Full automated bootstrap kicks in when ALL workshop secrets are present.
# In CI / unconfigured environments we skip the heavy steps and let the
# user invoke them manually.
if [ -n "$DT_ENVIRONMENT" ] && [ -n "$DT_API_TOKEN" ] && [ -n "$DT_PLATFORM_TOKEN" ] \
   && [ -z "$CI" ] && [ -z "$GITHUB_ACTIONS" ]; then
  printInfoSection "All workshop secrets present — auto-bootstrapping (~15-20 minutes)"
  bootstrapWorkshop || printWarn "bootstrapWorkshop encountered issues — re-run manually if needed"
else
  printInfoSection "Workshop bootstrap is opt-in"
  printInfo "Set DT_ENVIRONMENT, DT_API_TOKEN, DT_PLATFORM_TOKEN as Codespace secrets"
  printInfo "or run 'bootstrapWorkshop' manually."
fi

finalizePostCreation
printInfoSection "Your dev container finished creating"
