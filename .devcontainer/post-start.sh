#!/bin/bash
##############################################################
##  In here you add whatever action should happen after the container ha been created
##  such as exposing the application.
##############################################################
#Load the functions into the shell
source .devcontainer/util/source_framework.sh

#TODO: BeforeGoLive comment this so the Mkdocs are not exposed in the container.
# we want to monitor all interactions of the users in the live github pages.
#exposeMkdocs

# Load test against the astroshop frontend (locust + playwright)
# Skipped in CI to keep the integration test inside its time budget.
if [[ -z "$CI" && -z "$GITHUB_ACTIONS" ]]; then
  deployLoadgenerator
fi

printInfoSection "Your dev.container finished starting up"