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

# Workshop bootstrap (Astroshop + GitLab + seed repos + dtctl) is intentionally
# NOT run from post-create. The CI integration test only needs the framework
# basics; the workshop content takes 15+ minutes to come up. Users start the
# workshop on demand:
#
#   bootstrapWorkshop      # deploys astroshop + gitlab + seeds repos + installs dtctl
#
# See `bootstrapWorkshop` in .devcontainer/util/my_functions.sh.

# If the Codespace was created via Workflow end2end test will be done, otherwise
# it'll verify if there are error in the logs and will show them in the greeting as well a monitoring
# notification will be sent on the instantiation details
finalizePostCreation

printInfoSection "Your dev container finished creating"
printInfo "Workshop bootstrap is opt-in — run 'bootstrapWorkshop' to deploy"
printInfo "Astroshop + GitLab + seed repos + dtctl. Takes ~15-20 minutes."
