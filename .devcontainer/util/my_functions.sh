#!/bin/bash
# ======================================================================
#          ------- Custom Functions -------                            #
#  Migrated from perform-2025-hot-dynatrace-for-developers (ansible    #
#  roles) into bash. Three pillars:                                    #
#    installGitlab        — gitlab helm chart in-cluster               #
#    seedGitlabRepos      — create groups/projects, push local repos   #
#    deployLoadgenerator  — build locust image, deploy against         #
#                           astroshop                                  #
# ======================================================================

# Shared defaults — matches the ace-box roles and source repo
GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab}"
GITLAB_CHART_VERSION="${GITLAB_CHART_VERSION:-9.4.0}"
GITLAB_ROOT_USER="${GITLAB_ROOT_USER:-root}"
GITLAB_GROUP_OTEL="${GITLAB_GROUP_OTEL:-Otel-App}"
GITLAB_GROUP_SUPPORT="${GITLAB_GROUP_SUPPORT:-Support}"

MIGRATE_DIR="${MIGRATE_DIR:-$REPO_PATH/.devcontainer/migrate}"

LOADGEN_NAMESPACE="${LOADGEN_NAMESPACE:-astroshop-load}"
LOADGEN_IMAGE="${LOADGEN_IMAGE:-astroshop-loadgenerator:local}"
ASTROSHOP_NAMESPACE="${ASTROSHOP_NAMESPACE:-astroshop}"

customFunction(){
  printInfoSection "This is a custom function that calculates 1 + 1"
  printInfo "1 + 1 = $(( 1 + 1 ))"
}

# ----------------------------------------------------------------------
# dtctl — Dynatrace platform CLI (github.com/dynatrace-oss/dtctl)
# ----------------------------------------------------------------------
installDtctl(){
  printInfoSection "Installing dtctl"

  if command -v dtctl >/dev/null 2>&1; then
    printInfo "dtctl already installed: $(dtctl version 2>/dev/null | head -1)"
    return 0
  fi

  # Upstream install script handles arch detection + PATH setup
  curl -fsSL https://raw.githubusercontent.com/dynatrace-oss/dtctl/main/install.sh | sh

  if command -v dtctl >/dev/null 2>&1; then
    printInfo "dtctl installed: $(dtctl version 2>/dev/null | head -1)"
  else
    printWarn "dtctl install completed but binary not on PATH — open a new shell or check ~/.local/bin"
  fi
}

# Apply the declarative dtctl/ artifacts (dashboards, SLOs, guardians, workflows)
# Requires `dtctl auth login` to have been run, OR DT_OAUTH_* env vars set.
applyDtctlConfigs(){
  local dir="${1:-$REPO_PATH/dtctl}"
  if ! command -v dtctl >/dev/null 2>&1; then
    printWarn "dtctl not installed — skipping. Run installDtctl first."
    return 1
  fi
  if [ ! -d "$dir" ]; then
    printWarn "No dtctl config directory at $dir — skipping"
    return 0
  fi

  printInfoSection "Applying dtctl configs from $dir"
  local f
  for f in "$dir"/{dashboards,slos,guardians,workflows}/*.yaml; do
    [ -f "$f" ] || continue
    printInfo "  applying $(basename "$f")"
    dtctl apply -f "$f" || printWarn "  apply of $f failed"
  done
}

# ----------------------------------------------------------------------
# GitLab — install via official helm chart on sslip.io magic domain
# ----------------------------------------------------------------------
installGitlab(){
  printInfoSection "Installing GitLab (helm chart $GITLAB_CHART_VERSION) in namespace '$GITLAB_NAMESPACE'"

  local ip domain root_password
  ip=$(detectIP)
  domain="${ip}.${MAGIC_DOMAIN:-sslip.io}"

  kubectl create namespace "$GITLAB_NAMESPACE" 2>/dev/null || true

  # Generate root password once, persist as k8s secret so reruns reuse it
  if kubectl -n "$GITLAB_NAMESPACE" get secret ace-gitlab-initial-root-password &>/dev/null; then
    root_password=$(kubectl -n "$GITLAB_NAMESPACE" get secret ace-gitlab-initial-root-password \
      -o jsonpath='{.data.password}' | base64 -d)
    printInfo "Reusing existing gitlab root password"
  else
    root_password=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
    kubectl -n "$GITLAB_NAMESPACE" create secret generic ace-gitlab-initial-root-password \
      --from-literal="username=$GITLAB_ROOT_USER" \
      --from-literal="password=$root_password"
    printInfo "Created gitlab root password secret"
  fi

  helm repo add gitlab https://charts.gitlab.io/ >/dev/null
  helm repo update >/dev/null

  printInfo "Installing gitlab — ingress domain: gitlab.${domain}"
  helm upgrade --install gitlab gitlab/gitlab \
    --namespace "$GITLAB_NAMESPACE" \
    --version "$GITLAB_CHART_VERSION" \
    --wait --timeout 30m \
    --set "global.hosts.domain=${domain}" \
    --set "global.hosts.https=false" \
    --set "global.appConfig.initialDefaults.signupEnabled=false" \
    --set "global.ingress.provider=nginx" \
    --set "global.ingress.configureCertmanager=false" \
    --set "global.ingress.class=nginx" \
    --set "global.ingress.tls.enabled=false" \
    --set "global.initialRootPassword.secret=ace-gitlab-initial-root-password" \
    --set "global.initialRootPassword.key=password" \
    --set "installCertmanager=false" \
    --set "certmanager.install=false" \
    --set "nginx-ingress.enabled=false" \
    --set "gitlab-runner.rbac.create=true" \
    --set "gitlab-runner.rbac.clusterWideAccess=true" \
    --set "gitlab-runner.gitlabUrl=http://gitlab.${domain}"

  local endpoint
  endpoint=$(_gitlabInternalEndpoint)
  printInfo "Waiting for gitlab API at ${endpoint}/api/v4/projects to respond"
  local RETRY=0 RETRY_MAX=60 http_code=""
  while [[ $RETRY -lt $RETRY_MAX ]]; do
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' "${endpoint}/api/v4/projects" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
      printInfo "GitLab API is up (HTTP $http_code)"
      break
    fi
    RETRY=$((RETRY + 1))
    printWarn "Retry: ${RETRY}/${RETRY_MAX} - Wait 10s for GitLab API (last HTTP $http_code) ..."
    sleep 10
  done
  if [[ $RETRY -eq $RETRY_MAX ]]; then
    printError "GitLab API at ${endpoint} did not respond with 200 within $((RETRY_MAX * 10))s"
    return 1
  fi

  # Generate + persist a Personal Access Token for API/git operations
  _gitlabEnsurePat
  printInfo "GitLab available at: http://gitlab.${domain}"
  printInfo "Root credentials: $GITLAB_ROOT_USER / $root_password"

  # Wide-open RBAC like the source repo, so CI runners can do anything
  kubectl create clusterrolebinding gitlab-cluster-admin \
    --clusterrole=cluster-admin --group=system:serviceaccounts 2>/dev/null || true
}

uninstallGitlab(){
  printInfoSection "Uninstalling GitLab"
  helm uninstall gitlab -n "$GITLAB_NAMESPACE" 2>/dev/null || true
  kubectl delete namespace "$GITLAB_NAMESPACE" 2>/dev/null || true
}

# ----------------------------------------------------------------------
# GitLab — internal helpers (REST API + auth)
# ----------------------------------------------------------------------
_gitlabInternalEndpoint(){
  # Host-reachable ingress URL — the ClusterIP from gitlab-webservice-default
  # isn't routable from the dev container, so we use the sslip.io magic domain.
  local ip
  ip=$(detectIP)
  echo "http://gitlab.${ip}.${MAGIC_DOMAIN:-sslip.io}"
}

_gitlabRootPassword(){
  kubectl -n "$GITLAB_NAMESPACE" get secret ace-gitlab-initial-root-password \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d
}

_gitlabEnsurePat(){
  # If PAT already exists in k8s, source it; otherwise create via OAuth -> PAT
  if kubectl -n "$GITLAB_NAMESPACE" get secret ace-gitlab-root-pat &>/dev/null; then
    GITLAB_PAT=$(kubectl -n "$GITLAB_NAMESPACE" get secret ace-gitlab-root-pat \
      -o jsonpath='{.data.personalAccessToken}' | base64 -d)
    printInfo "Reusing existing gitlab PAT"
    return 0
  fi

  local endpoint password oauth_token pat
  endpoint=$(_gitlabInternalEndpoint)
  password=$(_gitlabRootPassword)

  oauth_token=$(curl -sk -X POST "${endpoint}/oauth/token" \
    -H "Content-Type: application/json" \
    -d "{\"grant_type\":\"password\",\"username\":\"${GITLAB_ROOT_USER}\",\"password\":\"${password}\"}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

  if [ -z "$oauth_token" ]; then
    printError "Could not get GitLab OAuth token"
    return 1
  fi

  pat=$(curl -sk -X POST "${endpoint}/api/v4/users/1/personal_access_tokens" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${oauth_token}" \
    -d '{"name":"ace-box-pat","scopes":["api","read_api","read_user","read_repository","write_repository","sudo","admin_mode"]}' \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

  if [ -z "$pat" ]; then
    printError "Could not create GitLab PAT"
    return 1
  fi

  kubectl -n "$GITLAB_NAMESPACE" create secret generic ace-gitlab-root-pat \
    --from-literal="personalAccessToken=$pat"
  GITLAB_PAT="$pat"
  printInfo "Created and persisted GitLab PAT"
}

_gitlabEnsureGroup(){
  # Usage: _gitlabEnsureGroup <group_name>
  # Echoes the group ID on stdout; logs go to stderr so callers can capture
  # the ID cleanly via $(...).
  local name="$1" endpoint id
  endpoint=$(_gitlabInternalEndpoint)

  id=$(curl -sk -H "Authorization: Bearer ${GITLAB_PAT}" \
    "${endpoint}/api/v4/groups?search=$(printf %s "$name" | jq -sRr @uri)" \
    | jq -r ".[] | select(.name==\"$name\") | .id" | head -n1)

  if [ -z "$id" ] || [ "$id" = "null" ]; then
    id=$(curl -sk -X POST "${endpoint}/api/v4/groups" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${GITLAB_PAT}" \
      -d "{\"path\":\"$name\",\"name\":\"$name\",\"visibility\":\"public\"}" \
      | jq -r '.id')
    printInfo "Created group '$name' (id=$id)" >&2
  else
    printInfo "Group '$name' already exists (id=$id)" >&2
  fi
  echo "$id"
}

_gitlabEnsureProject(){
  # Usage: _gitlabEnsureProject <project_name> <namespace_id>
  # Echoes the project ID on stdout; logs go to stderr so callers can capture
  # the ID cleanly via $(...).
  local name="$1" ns_id="$2" endpoint id
  endpoint=$(_gitlabInternalEndpoint)

  id=$(curl -sk -H "Authorization: Bearer ${GITLAB_PAT}" \
    "${endpoint}/api/v4/projects?search=$(printf %s "$name" | jq -sRr @uri)" \
    | jq -r ".[] | select(.name==\"$name\") | select(.namespace.id==$ns_id) | .id" | head -n1)

  if [ -z "$id" ] || [ "$id" = "null" ]; then
    id=$(curl -sk -X POST "${endpoint}/api/v4/projects" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${GITLAB_PAT}" \
      -d "{\"name\":\"$name\",\"namespace_id\":$ns_id,\"visibility\":\"public\"}" \
      | jq -r '.id')
    printInfo "  Created project '$name' (id=$id)" >&2
  else
    printInfo "  Project '$name' already exists (id=$id)" >&2
  fi
  echo "$id"
}

_gitlabPushRepo(){
  # Usage: _gitlabPushRepo <local_dir> <group> <project_name> [branch]
  local src="$1" group="$2" repo="$3" branch="${4:-main}"
  local endpoint host password
  endpoint=$(_gitlabInternalEndpoint)
  host="${endpoint#http://}"
  password=$(_gitlabRootPassword)

  if [ ! -d "$src" ] || [ -z "$(ls -A "$src" 2>/dev/null)" ]; then
    printWarn "  Skipping push for '$repo' — source dir '$src' empty/missing"
    return 0
  fi

  ( cd "$src"
    if [ ! -d .git ]; then
      git init -q -b "$branch"
      git config user.email "ace-box@local"
      git config user.name  "ace-box"
      git add .
      git commit -q -m "Initial commit for branch $branch" || true
    fi
    git remote remove gitlab 2>/dev/null || true
    git remote add gitlab "http://${GITLAB_ROOT_USER}:${password}@${host}/${group}/${repo}.git"
    git push -q gitlab "$branch" 2>&1 | sed 's/^/    /' || \
      printWarn "  Push of $repo failed (may already be populated)"
  )
}

# ----------------------------------------------------------------------
# GitLab — seed groups and push local repos
# ----------------------------------------------------------------------
seedGitlabRepos(){
  printInfoSection "Seeding GitLab repositories from $MIGRATE_DIR"

  if [ -z "$GITLAB_PAT" ]; then
    _gitlabEnsurePat || return 1
  fi

  # Support group (3 repos: monaco, automated load test, manual release)
  local support_id
  support_id=$(_gitlabEnsureGroup "$GITLAB_GROUP_SUPPORT")
  local s
  for s in dynatrace_env_automation automated_load_test astroshop_release_repo; do
    _gitlabEnsureProject "$s" "$support_id" >/dev/null
    _gitlabPushRepo "$MIGRATE_DIR/support_repos/$s" "$GITLAB_GROUP_SUPPORT" "$s"
  done

  # Otel-App group (all 19 astroshop service repos)
  local otel_id
  otel_id=$(_gitlabEnsureGroup "$GITLAB_GROUP_OTEL")
  local r
  for r in "$MIGRATE_DIR"/astroshop_repos/*/; do
    [ -d "$r" ] || continue
    local name
    name=$(basename "$r")
    _gitlabEnsureProject "$name" "$otel_id" >/dev/null
    _gitlabPushRepo "$r" "$GITLAB_GROUP_OTEL" "$name"
  done

  printInfo "GitLab seeding complete"
}

# ----------------------------------------------------------------------
# Load generator — build the locust image and deploy to k8s
# ----------------------------------------------------------------------
buildLoadgenImage(){
  printInfoSection "Building loadgenerator image '$LOADGEN_IMAGE'"
  local src="$MIGRATE_DIR/astroshop_repos/loadgenerator"

  if [ ! -f "$src/Dockerfile" ]; then
    printError "Loadgenerator sources not found at $src"
    return 1
  fi

  docker build -t "$LOADGEN_IMAGE" "$src"

  # Import into k3d so the cluster can pull it without a registry
  if command -v k3d >/dev/null 2>&1; then
    local cluster="${K3D_CLUSTER_NAME:-enablement}"
    printInfo "Importing $LOADGEN_IMAGE into k3d cluster '$cluster'"
    k3d image import "$LOADGEN_IMAGE" -c "$cluster"
  else
    printWarn "k3d not found — assuming the image is reachable from the cluster"
  fi
}

deployLoadgenerator(){
  printInfoSection "Deploying loadgenerator to namespace '$LOADGEN_NAMESPACE'"

  local src="$MIGRATE_DIR/astroshop_repos/loadgenerator"
  if [ ! -f "$src/deploy.yaml" ]; then
    printError "deploy.yaml not found at $src"
    return 1
  fi

  # Build the image if it's not in the local docker yet
  if ! docker image inspect "$LOADGEN_IMAGE" >/dev/null 2>&1; then
    buildLoadgenImage || return 1
  fi

  # Target astroshop's user-facing URL — uses the framework's ingress/sslip.io
  local target
  target=$(getAppURL astroshop 2>/dev/null)
  [ -z "$target" ] && target="http://astroshop-frontend.${ASTROSHOP_NAMESPACE}.svc.cluster.local:8080"
  printInfo "Loadgen will target: $target"

  kubectl create namespace "$LOADGEN_NAMESPACE" 2>/dev/null || true

  # Substitute image + host placeholders from deploy.yaml and apply
  sed -e "s|IMAGE_PLACEHOLDER|${LOADGEN_IMAGE}|g" \
      -e "s|https://PLACEHOLDER_DOMAIN|${target}|g" \
      -e "s|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|g" \
      "$src/deploy.yaml" \
    | kubectl apply -n "$LOADGEN_NAMESPACE" -f -

  printInfo "Loadgenerator deployed — check status with: kubectl -n $LOADGEN_NAMESPACE get pods"
}

undeployLoadgenerator(){
  printInfoSection "Removing loadgenerator"
  kubectl delete deployment astroshop-loadgenerator -n "$LOADGEN_NAMESPACE" 2>/dev/null || true
}

# ----------------------------------------------------------------------
# CI/CD Observability — feed the community app with SDLC events
# (the app itself is "available upon request" — ask your DT contact to
# activate; in the meantime, send data so the ingest pipeline is proven.)
# ----------------------------------------------------------------------
# Required env vars when invoking:
#   DT_TENANT_URL    e.g. https://abc12345.live.dynatrace.com
#   DT_API_TOKEN     token with scope: openpipeline.events.ingest
# Optional:
#   DT_CICD_PROVIDER (default: astroshop) — the path segment after events.sdlc/

_dtSdlcEndpoint(){
  local provider="${DT_CICD_PROVIDER:-astroshop}"
  echo "${DT_TENANT_URL%/}/platform/ingest/custom/events.sdlc/${provider}"
}

# Send one event JSON (array or single) to the SDLC ingest endpoint
_dtSdlcPost(){
  local body="$1"
  if [ -z "$DT_TENANT_URL" ] || [ -z "$DT_API_TOKEN" ]; then
    printError "DT_TENANT_URL and DT_API_TOKEN must be set"
    return 1
  fi
  local url code
  url=$(_dtSdlcEndpoint)
  code=$(curl -sk -o /tmp/.sdlc-resp -w '%{http_code}' \
    -X POST "$url" \
    -H "Authorization: Api-Token $DT_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body")
  if [[ "$code" =~ ^2 ]]; then
    printInfo "  SDLC ingest OK (HTTP $code)"
  else
    printWarn "  SDLC ingest HTTP $code: $(cat /tmp/.sdlc-resp 2>/dev/null | head -c 200)"
  fi
}

# Emit one pipeline-run event matching the community app schema.
# Usage: sendPipelineEvent <pipeline_id> <run_id> <pipeline_name> <outcome> <branch> <repo> [trigger_user] [duration_s]
sendPipelineEvent(){
  local pid="$1" rid="$2" name="$3" outcome="$4" branch="$5" repo="$6"
  local user="${7:-ci-bot}" dur="${8:-180}"
  local now end_ts start_ts
  end_ts=$(date -u +"%Y-%m-%dT%H:%M:%S.000000000Z")
  start_ts=$(date -u -d "@$(( $(date +%s) - dur ))" +"%Y-%m-%dT%H:%M:%S.000000000Z")

  local body
  body=$(cat <<JSON
{
  "cicd.pipeline.id": "${pid}",
  "cicd.pipeline.run.id": ${rid},
  "cicd.pipeline.name": "${name}",
  "cicd.pipeline.run.outcome": "${outcome}",
  "cicd.pipeline.run.url.full": "https://gitlab.local/${repo}/pipelines/${rid}",
  "ext.pipeline.build.name": "build ${rid} on ${branch}",
  "ext.pipeline.run.trigger.user": "${user}",
  "vcs.ref.head.name": "${branch}",
  "vcs.repository.name": "${repo}",
  "event.category": "pipeline",
  "event.status": "finished",
  "event.type": "deploy",
  "event.provider": "${DT_CICD_PROVIDER:-astroshop}",
  "duration": ${dur},
  "start_time": "${start_ts}",
  "end_time": "${end_ts}"
}
JSON
)
  _dtSdlcPost "$body"
}

# Emit one task/job event matching the community app schema.
# Usage: sendTaskEvent <task_id> <task_name> <outcome> <pipeline_id> <run_id> <pipeline_name> <branch> [duration_s]
sendTaskEvent(){
  local tid="$1" tname="$2" outcome="$3" pid="$4" rid="$5" pname="$6" branch="$7"
  local dur="${8:-60}"
  local end_ts start_ts
  end_ts=$(date -u +"%Y-%m-%dT%H:%M:%S.000000000Z")
  start_ts=$(date -u -d "@$(( $(date +%s) - dur ))" +"%Y-%m-%dT%H:%M:%S.000000000Z")

  local body
  body=$(cat <<JSON
{
  "task.id": "${tid}",
  "task.name": "${tname}",
  "task.outcome": "${outcome}",
  "cicd.pipeline.run.id": ${rid},
  "cicd.pipeline.id": "${pid}",
  "cicd.pipeline.name": "${pname}",
  "vcs.ref.head.name": "${branch}",
  "task.retry": 1,
  "event.category": "task",
  "event.status": "finished",
  "event.type": "deploy",
  "event.provider": "${DT_CICD_PROVIDER:-astroshop}",
  "duration": ${dur},
  "start_time": "${start_ts}",
  "end_time": "${end_ts}"
}
JSON
)
  _dtSdlcPost "$body"
}

# Seed a realistic 4-release demo pipeline run with its tasks. Mirrors the
# HOT2025 workshop's flow: 1.12.0/none → 1.12.1/cpu → 1.12.2/memory → 1.12.3/n+1
seedCicdPipelineData(){
  printInfoSection "Seeding CI/CD Observability app with demo SDLC events"
  if [ -z "$DT_TENANT_URL" ] || [ -z "$DT_API_TOKEN" ]; then
    printWarn "DT_TENANT_URL and DT_API_TOKEN not set — skipping"
    return 0
  fi

  local pid="astroshop-release"
  local pname="Astroshop release pipeline"
  local branch="main" repo="Otel-App/astroshop"

  local i
  for i in 0 1 2 3; do
    local version problem outcome
    case $i in
      0) version="1.12.0"; problem="none";     outcome="success" ;;
      1) version="1.12.1"; problem="cpu";      outcome="failed"  ;;
      2) version="1.12.2"; problem="memory";   outcome="failed"  ;;
      3) version="1.12.3"; problem="nplusone"; outcome="failed"  ;;
    esac
    local rid=$(( 10000 + i ))

    printInfo "Release ${version} (${problem}) → outcome=${outcome}"
    sendPipelineEvent "$pid" "$rid" "$pname" "$outcome" "$branch" "$repo" "demo-runner" 240

    # Tasks that compose the pipeline run
    sendTaskEvent "${rid}-build"     "build"          "success"  "$pid" "$rid" "$pname" "$branch"  45
    sendTaskEvent "${rid}-deploy"    "deploy-staging" "success"  "$pid" "$rid" "$pname" "$branch"  60
    sendTaskEvent "${rid}-loadtest"  "loadtest"       "success"  "$pid" "$rid" "$pname" "$branch" 120
    if [ "$outcome" = "success" ]; then
      sendTaskEvent "${rid}-guardian" "srg-evaluate" "success" "$pid" "$rid" "$pname" "$branch" 15
      sendTaskEvent "${rid}-promote"  "promote-prod" "success" "$pid" "$rid" "$pname" "$branch" 30
    else
      sendTaskEvent "${rid}-guardian" "srg-evaluate" "failed"  "$pid" "$rid" "$pname" "$branch" 15
      sendTaskEvent "${rid}-rollback" "rollback"     "success" "$pid" "$rid" "$pname" "$branch" 20
    fi
  done

  printInfo "Done — open the CI/CD Observability app in your tenant to verify"
}

# Send a CUSTOM_DEPLOYMENT event to Events v2 — single source of truth for the
# Davis correlation layer. Reads the same env vars as the SDLC helpers.
# Usage: sendDeploymentEvent <version> <stage> <problem> [pipeline_url]
sendDeploymentEvent(){
  local version="$1" stage="${2:-staging}" problem="${3:-none}"
  local ci_url="${4:-${CI_JOB_URL:-https://gitlab.local}}"

  if [ -z "$DT_TENANT_URL" ] || [ -z "$DT_API_TOKEN" ]; then
    printWarn "DT_TENANT_URL and DT_API_TOKEN not set — skipping"
    return 0
  fi

  local body
  body=$(cat <<JSON
{
  "eventType": "CUSTOM_DEPLOYMENT",
  "title": "astroshop release ${version} (${problem})",
  "entitySelector": "type(SERVICE),toRelationships.partOf(type(NAMESPACE),entityName.equals(astroshop))",
  "timeout": 5,
  "properties": {
    "deploymentName": "astroshop release ${version}",
    "deploymentVersion": "${version}",
    "deploymentProject": "astroshop",
    "ciBackLink": "${ci_url}",
    "Release_Stage": "${stage}",
    "Application": "astroshop",
    "PROBLEM": "${problem}"
  }
}
JSON
)
  local code
  code=$(curl -sk -o /tmp/.event-resp -w '%{http_code}' \
    -X POST "${DT_TENANT_URL%/}/api/v2/events/ingest" \
    -H "Authorization: Api-Token $DT_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body")
  if [[ "$code" =~ ^2 ]]; then
    printInfo "CUSTOM_DEPLOYMENT $version ($problem) → HTTP $code"
  else
    printWarn "Deployment event HTTP $code: $(cat /tmp/.event-resp | head -c 200)"
  fi
}

# ----------------------------------------------------------------------
# bootstrapWorkshop — one command to bring up the full workshop content
#
# Why this is opt-in rather than in post-create:
#   - installGitlab needs ~10 min for the helm chart to converge
#   - sslip.io ingress is not reachable from CI runners (no ingress
#     controller in scope), so installGitlab's wait loop hangs in CI
#   - the CI integration test only validates framework basics; the
#     workshop content is for Codespaces / local devcontainers
#
# Run order matters: cluster must be up; astroshop first (its ingress
# is needed for the load test target URL); then gitlab + repos so the
# load generator has somewhere to push from; then dtctl last (cheap).
# ----------------------------------------------------------------------
bootstrapWorkshop(){
  printInfoSection "Bootstrapping the CI/CD Observability workshop"
  printInfo "Phases: astroshop -> gitlab -> seed repos -> dtctl -> loadgen"
  printInfo "Total time: ~15-20 minutes"

  deployApp astroshop          || { printError "astroshop deploy failed"; return 1; }
  installGitlab                || { printError "gitlab install failed"; return 1; }
  seedGitlabRepos              || { printError "gitlab seed failed"; return 1; }
  installDtctl                 || printWarn "dtctl install failed (non-fatal)"
  deployLoadgenerator          || printWarn "loadgen deploy failed (non-fatal)"

  printInfoSection "Workshop bootstrap complete"
  printInfo "GitLab:   http://gitlab.$(detectIP).${MAGIC_DOMAIN:-sslip.io}"
  printInfo "Astroshop: $(getAppURL astroshop 2>/dev/null || echo 'see printGreeting')"
  printInfo "Next: dtctl auth login --context demo --environment <tenant>; applyDtctlConfigs"
}
