#!/bin/bash
# TEST BRANCH (staging, 101-perform-staging) — smallest Perform training:
# K3d + ingress + ToDo app + GitLab (Omnibus + Runner) + code-server installed.
# Framework pinned to codespaces-framework branch perform-staging-101 (= cff0018, #193).
# Not a production training; do not merge.
export SECONDS=0
source .devcontainer/util/source_framework.sh

setUpTerminal
startCluster
installIngressController
deployTodoApp
deployGitlab
# Pre-install code-server so Orbital's lazy start (ide-link) does not download ~700 MB.
installCodeServer

finalizePostCreation
printInfoSection "Perform test environment ready in ${SECONDS}s"
