#!/bin/bash
#loading functions to script
export SECONDS=0
source .devcontainer/util/source_framework.sh

setUpTerminal

startK3dCluster

installK9s

#installMkdocs

# Dynatrace Operator can be deployed automatically
#dynatraceDeployOperator

# You can deploy CNFS or AppOnly
#deployCloudNative
#deployApplicationMonitoring

# The Astroshop keeping changes of demo.live needs certmanagerdocker
deployApp astroshop

# Heavy steps below — skipped in CI (10-min integration-test budget). The
# integration test exercises the framework + astroshop only; the workshop
# extras run in Codespaces / local devcontainers.
if [[ -z "$CI" && -z "$GITHUB_ACTIONS" ]]; then
  # GitLab in-cluster + seed Otel-App / Support groups with the migrated repos
  installGitlab
  seedGitlabRepos
  # Dynatrace platform CLI for dashboards/SLOs/guardians/workflows-as-code
  installDtctl
else
  printInfo "CI detected — skipping installGitlab / seedGitlabRepos / installDtctl"
fi

# If the Codespace was created via Workflow end2end test will be done, otherwise
# it'll verify if there are error in the logs and will show them in the greeting as well a monitoring 
# notification will be sent on the instantiation details
finalizePostCreation

printInfoSection "Your dev container finished creating"
