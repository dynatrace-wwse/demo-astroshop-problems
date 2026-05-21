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
# monaco — Dynatrace Monitoring-as-Code CLI
# (github.com/Dynatrace/dynatrace-configuration-as-code)
# ----------------------------------------------------------------------
MONACO_VERSION="${MONACO_VERSION:-2.28.7}"

installMonaco(){
  printInfoSection "Installing monaco v$MONACO_VERSION"
  if command -v monaco >/dev/null 2>&1; then
    printInfo "monaco already installed: $(monaco version 2>/dev/null | head -1)"
    return 0
  fi
  local bindir="$HOME/.local/bin"
  mkdir -p "$bindir"
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) printError "unsupported arch $(uname -m)"; return 1 ;;
  esac
  curl -fsSL "https://github.com/Dynatrace/dynatrace-configuration-as-code/releases/download/v${MONACO_VERSION}/monaco-linux-${arch}" \
    -o "$bindir/monaco"
  chmod +x "$bindir/monaco"
  case ":$PATH:" in *":$bindir:"*) ;; *) export PATH="$bindir:$PATH" ;; esac
  printInfo "monaco installed: $(monaco version 2>/dev/null | head -1)"
}

# Apply the monaco config under
# .devcontainer/migrate/support_repos/dynatrace_env_automation/monaco/ to the
# current DT_ENVIRONMENT. Requires:
#   DT_ENVIRONMENT          tenant platform URL (https://<id>.apps.dynatrace.com)
#   DT_API_TOKEN            classic Api-Token (any read scope is enough)
#   DT_PLATFORM_TOKEN       OAuth platform token (dt0s16...) — the source of truth
# Optional (defaults wired so monaco can still deploy on COE-only tenants):
#   WORKFLOW_ACTOR_ID       owner UUID for workflows
#   GITLAB_EXTERNAL_ENDPOINT, GITLAB_HOST, GITLAB_PRIVATE_TOKEN  — set when the
#                           in-cluster GitLab is reachable from this tenant
#   ACTIVE_GATE_NODE_ID     synthetic location host (needed for synthetic monitor)
applyMonacoConfig(){
  local monaco_dir="${MONACO_DIR:-$REPO_PATH/.devcontainer/migrate/support_repos/dynatrace_env_automation/monaco}"
  if [ ! -f "$monaco_dir/manifest.yml" ]; then
    printWarn "No monaco manifest at $monaco_dir/manifest.yml — skipping"
    return 0
  fi
  if [ -z "$DT_ENVIRONMENT" ] || [ -z "$DT_PLATFORM_TOKEN" ]; then
    printWarn "DT_ENVIRONMENT or DT_PLATFORM_TOKEN not set — skipping monaco deploy"
    return 0
  fi

  installMonaco

  printInfoSection "Applying monaco config from $monaco_dir to $DT_ENVIRONMENT"
  # Map / fill the env vars monaco expects from what we have.
  export DT_PLATFORM_TENANT_URL="$DT_ENVIRONMENT"
  export DT_API_TOKEN="${DT_API_TOKEN:?DT_API_TOKEN must be set}"
  export DT_PLATFORM_TOKEN
  : "${WORKFLOW_ACTOR_ID:=00000000-0000-0000-0000-000000000000}"
  : "${DT_TENANT_URL_NO_HTTP:=$(echo "$DT_ENVIRONMENT" | sed -E 's|https?://||')}"
  : "${GITLAB_EXTERNAL_ENDPOINT:=http://gitlab.placeholder.sslip.io}"
  : "${GITLAB_HOST:=gitlab.placeholder.sslip.io}"
  : "${GITLAB_PRIVATE_TOKEN:=placeholder-gitlab-pat}"
  : "${ACTIVE_GATE_NODE_ID:=placeholder-ag-node}"
  export WORKFLOW_ACTOR_ID DT_TENANT_URL_NO_HTTP \
         GITLAB_EXTERNAL_ENDPOINT GITLAB_HOST GITLAB_PRIVATE_TOKEN \
         ACTIVE_GATE_NODE_ID

  ( cd "$monaco_dir" && monaco deploy manifest.yml --continue-on-error ) \
    | grep -E "Deployment successful|ERROR|configs deployed" | tail -20
  printInfo "monaco deploy finished (see ${monaco_dir}/.logs/ for full output)"
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

  # Substitute image + host placeholders from deploy.yaml and apply.
  # We then scale the deployment to 0 so the loadgen DOES NOT run
  # continuously — TSN/LTN/LSN headers must only be emitted around
  # an explicit load-test window. Use startLoadtest / stopLoadtest
  # (or let rollAstroshopRelease handle it for you).
  sed -e "s|IMAGE_PLACEHOLDER|${LOADGEN_IMAGE}|g" \
      -e "s|https://PLACEHOLDER_DOMAIN|${target}|g" \
      -e "s|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|g" \
      "$src/deploy.yaml" \
    | kubectl apply -n "$LOADGEN_NAMESPACE" -f -

  # Scale to 0 — IMPORTANT: the workshop loadgen must be opt-in.
  # Continuous traffic with x-dynatrace-test headers pollutes the
  # SRG signal and makes "no test step data" impossible to verify.
  kubectl -n "$LOADGEN_NAMESPACE" scale deployment astroshop-loadgenerator --replicas=0 \
    >/dev/null 2>&1 || true

  printInfo "Loadgenerator deployed (scaled to 0 — start with 'startLoadtest')"
}

undeployLoadgenerator(){
  printInfoSection "Removing loadgenerator"
  kubectl delete deployment astroshop-loadgenerator -n "$LOADGEN_NAMESPACE" 2>/dev/null || true
}

# startLoadtest — scale the workshop loadgen up for a controlled load
# window. Each request carries the x-dynatrace-test header that the
# monaco request-attribute rules unpack into TSN/LTN/LSN on spans.
# Usage: startLoadtest [replicas]
startLoadtest(){
  local n="${1:-1}"
  if ! kubectl -n "$LOADGEN_NAMESPACE" get deployment astroshop-loadgenerator >/dev/null 2>&1; then
    printWarn "Loadgen not deployed — running deployLoadgenerator first"
    deployLoadgenerator || return 1
  fi
  printInfoSection "Starting workshop loadtest (replicas=$n)"
  kubectl -n "$LOADGEN_NAMESPACE" scale deployment astroshop-loadgenerator --replicas="$n"
  kubectl -n "$LOADGEN_NAMESPACE" rollout status deployment astroshop-loadgenerator --timeout=60s 2>&1 | tail -1
  printInfo "Loadtest running. Stop with 'stopLoadtest'."
}

# stopLoadtest — scale workshop loadgen back to 0. TSN/LTN/LSN
# traffic stops at the next request.
stopLoadtest(){
  printInfoSection "Stopping workshop loadtest"
  kubectl -n "$LOADGEN_NAMESPACE" scale deployment astroshop-loadgenerator --replicas=0 \
    2>&1 | tail -1
  printInfo "Loadtest stopped — x-dynatrace-test headers cease at next request."
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
#   DT_CICD_PROVIDER (default: gitlab) — the path segment after events.sdlc/
#                                          The repo runs a self-hosted GitLab
#                                          in-cluster, so 'gitlab' is the
#                                          natural value. Override to
#                                          'github' if you wire from there.
#                                          'github' matches the OpenPipeline
#                                          rules installed by the community
#                                          CI/CD Observability app wizard.

_dtSdlcEndpoint(){
  local provider="${DT_CICD_PROVIDER:-gitlab}"
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
  "event.provider": "${DT_CICD_PROVIDER:-gitlab}",
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
  "event.provider": "${DT_CICD_PROVIDER:-gitlab}",
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
  # extra_vars.* are read by the monaco SRG workflow's task expressions
  # (init_configs/labs/srg-workflow.json) — keep them on the payload so
  # the workflow can run end-to-end without modification.
  body=$(cat <<JSON
{
  "eventType": "CUSTOM_DEPLOYMENT",
  "title": "astroshop release ${version} (${problem})",
  "entitySelector": "type(SERVICE),entityName.startsWith(astroshop-)",
  "timeout": 5,
  "properties": {
    "deploymentName": "astroshop release ${version}",
    "deploymentVersion": "${version}",
    "deploymentProject": "astroshop",
    "ciBackLink": "${ci_url}",
    "Release_Stage": "${stage}",
    "Application": "astroshop",
    "PROBLEM": "${problem}",
    "extra_vars.release_version": "${version}",
    "extra_vars.problem": "${problem}",
    "extra_vars.pipeline_url": "${ci_url}",
    "extra_vars.dt_url": "${DT_ENVIRONMENT:-${DT_TENANT_URL}}"
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

  # Also fire a bizevent so the monaco-deployed SRG workflow auto-triggers.
  # The workflow listens with filterQuery: service == "astroshop" AND stage == "staging".
  if [ -n "$DT_BIZEVENTS_TOKEN" ]; then
    local biz
    biz=$(cat <<JSON
[{
  "event.type":                "release.staged",
  "event.provider":            "${DT_CICD_PROVIDER:-gitlab}",
  "service":                   "astroshop",
  "stage":                     "${stage}",
  "deploymentVersion":         "${version}",
  "PROBLEM":                   "${problem}",
  "ciBackLink":                "${ci_url}",
  "extra_vars.release_version":"${version}",
  "extra_vars.problem":        "${problem}",
  "extra_vars.pipeline_url":   "${ci_url}",
  "extra_vars.dt_url":         "${DT_ENVIRONMENT:-${DT_TENANT_URL}}",
  "timeframe.from":            "now-15m",
  "timeframe.to":              "now"
}]
JSON
)
    code=$(curl -sk -o /tmp/.biz-resp -w '%{http_code}' \
      -X POST "${DT_TENANT_URL%/}/api/v2/bizevents/ingest" \
      -H "Authorization: Api-Token $DT_BIZEVENTS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$biz")
    if [[ "$code" =~ ^2 ]]; then
      printInfo "  bizevent (trigger for SRG workflow) → HTTP $code"
    else
      printWarn "  bizevent HTTP $code: $(cat /tmp/.biz-resp | head -c 200)"
    fi
  else
    printWarn "  DT_BIZEVENTS_TOKEN not set — SRG workflow will not auto-trigger"
  fi
}

# ----------------------------------------------------------------------
# runDeploymentValidation — emit the verdict bizevent that an SRG would
# normally write. Deterministic: problem=none -> pass, anything else -> fail.
# Use until a real SRG document is in place; the verdict shape is identical.
# ----------------------------------------------------------------------
runDeploymentValidation(){
  local version="$1" stage="${2:-staging}" problem="${3:-none}"
  local verdict="pass"
  [ "$problem" != "none" ] && verdict="fail"

  if [ -z "$DT_TENANT_URL" ] || [ -z "$DT_API_TOKEN" ]; then
    printWarn "DT_TENANT_URL and DT_API_TOKEN not set — skipping"
    return 0
  fi

  local body
  body=$(cat <<JSON
{
  "event.provider":         "${DT_CICD_PROVIDER:-gitlab}",
  "event.type":             "guardian.evaluation",
  "event.category":         "guardian",
  "event.status":           "finished",
  "srg.guardian.id":        "release-readiness",
  "srg.guardian.name":      "Release readiness — astroshop",
  "srg.verdict":            "${verdict}",
  "deploymentProject":      "astroshop",
  "deploymentVersion":      "${version}",
  "Release_Stage":          "${stage}",
  "PROBLEM":                "${problem}"
}
JSON
)
  # Reuse the SDLC events endpoint we already have a scope for — the
  # event.category=guardian discriminator keeps it separate from pipeline data.
  local url code
  url=$(_dtSdlcEndpoint)
  code=$(curl -sk -o /tmp/.verdict-resp -w '%{http_code}' \
    -X POST "$url" \
    -H "Authorization: Api-Token $DT_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body")
  if [[ "$code" =~ ^2 ]]; then
    printInfo "Guardian verdict for $version ($problem) = $verdict → HTTP $code"
  else
    printWarn "Verdict HTTP $code: $(cat /tmp/.verdict-resp | head -c 200)"
  fi
}

# ----------------------------------------------------------------------
# rollAstroshopRelease — actually roll a release on the Astroshop
# deployments so the new pods carry the release version on labels +
# pod-template annotations. The original ace-box workshop did this via
# `helm upgrade --set default.image.tag=1.12.x`; the framework
# deployApp astroshop deploys static yaml so we have to patch.
#
# Usage:  rollAstroshopRelease <version> [problem] [services...]
# Example: rollAstroshopRelease 1.12.1 cpu
# Without `services...` we roll the user-facing entrypoints + the
# services the SRG cares about (frontend / frontend-proxy / cart / ad /
# product-catalog / checkout). One pod restart per service.
#
# What this updates on each deployment's pod template:
#   - label  app.kubernetes.io/version: <version>
#   - label  release:                  <version>
#   - label  problem:                  <problem>
#   - annot. metadata.dynatrace.com/release.version: <version>
#   - annot. metadata.dynatrace.com/release.problem: <problem>
# Davis treats the label change + pod restart as a deployment boundary.
ASTROSHOP_RELEASE_TARGETS=(frontend frontend-proxy cart ad product-catalog checkout recommendation payment accounting fraud-detection)

# k8s deployment name → docker hub image suffix (different naming styles).
# Used to construct shinojosa/astroshop:<version>-<suffix> per service.
_astroshopImageSuffix(){
  case "$1" in
    accounting)      echo "accountingservice" ;;
    ad)              echo "adservice" ;;
    cart)            echo "cartservice" ;;
    checkout)        echo "checkoutservice" ;;
    currency)        echo "currencyservice" ;;
    email)           echo "emailservice" ;;
    fraud-detection) echo "frauddetectionservice" ;;
    frontend)        echo "frontend" ;;
    frontend-proxy)  echo "frontendproxy" ;;
    image-provider)  echo "imageprovider" ;;
    load-generator)  echo "loadgenerator" ;;
    payment)         echo "paymentservice" ;;
    product-catalog) echo "productcatalogservice" ;;
    quote)           echo "quoteservice" ;;
    recommendation)  echo "recommendationservice" ;;
    shipping)        echo "shippingservice" ;;
    *) echo "" ;;
  esac
}

rollAstroshopRelease(){
  local version="${1:?usage: rollAstroshopRelease <version> [problem] [services...]}"
  local problem="${2:-none}"
  shift 2 2>/dev/null || shift $(( $# > 0 ? 1 : 0 )) 2>/dev/null
  local targets=("$@")
  [ ${#targets[@]} -eq 0 ] && targets=("${ASTROSHOP_RELEASE_TARGETS[@]}")

  printInfoSection "Rolling Astroshop release ${version} (${problem}) on ${#targets[@]} services"

  # Patch each deployment with:
  #   * the actual release IMAGE (shinojosa/astroshop:<version>-<suffix>)
  #     so the bugs baked into 1.12.1/2/3 actually run; 1.12.0 is the
  #     baseline. This is the ace-box workshop's mechanism — different
  #     pre-built images per release, not feature flags.
  #   * pod-template labels + annotations so dashboards can filter by
  #     release and Davis recognises the deployment boundary.
  #   * OTEL_RESOURCE_ATTRIBUTES so OTel-instrumented services emit
  #     service.version=<release> on every span.
  local svc
  for svc in "${targets[@]}"; do
    if ! kubectl -n "$ASTROSHOP_NAMESPACE" get deployment "$svc" >/dev/null 2>&1; then
      printWarn "  no deployment '$svc' — skipping"
      continue
    fi

    # Swap the container image to the per-release variant.
    local suffix
    suffix=$(_astroshopImageSuffix "$svc")
    if [ -n "$suffix" ]; then
      local image="docker.io/shinojosa/astroshop:${version}-${suffix}"
      # Get the first container's name (varies — kafka has "kafka", flagd has "flagd-ui" + flagd, etc.)
      local container
      container=$(kubectl -n "$ASTROSHOP_NAMESPACE" get deployment "$svc" \
        -o jsonpath='{.spec.template.spec.containers[0].name}')
      kubectl -n "$ASTROSHOP_NAMESPACE" set image deployment/"$svc" "${container}=${image}" \
        >/dev/null 2>&1 || true
      printInfo "  ${svc} ← image ${image}"
    fi

    kubectl -n "$ASTROSHOP_NAMESPACE" patch deployment "$svc" --type=strategic --patch \
      "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"app.kubernetes.io/version\":\"${version}\",\"release\":\"${version}\",\"problem\":\"${problem}\"},\"annotations\":{\"metadata.dynatrace.com/release.version\":\"${version}\",\"metadata.dynatrace.com/release.problem\":\"${problem}\"}}}}}" \
      >/dev/null

    kubectl -n "$ASTROSHOP_NAMESPACE" set env deployment/"$svc" \
      "OTEL_RESOURCE_ATTRIBUTES=service.name=\$(OTEL_SERVICE_NAME),service.namespace=astroshop,service.version=${version},release=${version},problem=${problem}" \
      >/dev/null 2>&1 || true
  done

  # Wait for the rolling restart to finish on each
  for svc in "${targets[@]}"; do
    kubectl -n "$ASTROSHOP_NAMESPACE" rollout status deployment/"$svc" --timeout=60s 2>&1 \
      | tail -1 | sed "s/^/  /"
  done

  # Fire the deployment event + bizevent (Davis correlation + workflow trigger)
  sendDeploymentEvent "$version" staging "$problem"

  # Run the controlled load test against the new release. The
  # x-dynatrace-test header (LSN/LTN/TSN) ONLY appears in spans during
  # this window — outside the window the always-on OTel-demo
  # load-generator drives traffic without those headers.
  local soak="${LOADTEST_SOAK_SECONDS:-180}"
  printInfo "Starting load test window of ${soak}s for ${version}"
  startLoadtest >/dev/null 2>&1
  sleep "$soak"
  stopLoadtest  >/dev/null 2>&1
  printInfo "Load test window ended — TSN/LTN/LSN traffic stops"
}

# seedWorkshopReleases — end-to-end demo data: for each of the four
# release variants, fire the deployment event + pipeline-run SDLC event
# + per-deployment SRG verdict bizevent. Matches the "good build vs bad
# build" story: 1.12.0 passes, 1.12.1/2/3 fail.
# ----------------------------------------------------------------------
seedWorkshopReleases(){
  printInfoSection "Seeding workshop releases (gitlab provider, 4 variants)"
  local i version problem outcome verdict
  for i in 0 1 2 3; do
    case $i in
      0) version="1.12.0"; problem="none"     ;;
      1) version="1.12.1"; problem="cpu"      ;;
      2) version="1.12.2"; problem="memory"   ;;
      3) version="1.12.3"; problem="nplusone" ;;
    esac
    if [ "$problem" = "none" ]; then
      outcome="success"; verdict="pass"
    else
      outcome="failed";  verdict="fail"
    fi
    printInfo "── ${version} (${problem}) → outcome=${outcome} verdict=${verdict}"

    # 1. Roll the release on the astroshop deployments — patches pod
    #    template labels (app.kubernetes.io/version, release, problem)
    #    + annotations, restarts the pods, then fires the
    #    CUSTOM_DEPLOYMENT event + bizevent that triggers the SRG
    #    workflow. Falls back to event-only if not in-cluster.
    if kubectl get ns "$ASTROSHOP_NAMESPACE" >/dev/null 2>&1; then
      rollAstroshopRelease "$version" "$problem"
    else
      sendDeploymentEvent "$version" staging "$problem"
    fi
    local now start
    now=$(date -u +"%Y-%m-%dT%H:%M:%S.000000000Z")
    start=$(date -u -d "30 seconds ago" +"%Y-%m-%dT%H:%M:%S.000000000Z")
    _dtSdlcPost "$(cat <<JSON
{
  "event.provider":      "${DT_CICD_PROVIDER:-gitlab}",
  "event.category":      "deployment",
  "event.type":          "deploy",
  "event.status":        "finished",
  "deploymentProject":   "astroshop",
  "deploymentVersion":   "${version}",
  "Release_Stage":       "staging",
  "PROBLEM":             "${problem}",
  "vcs.repository.name": "Otel-App/astroshop",
  "vcs.ref.head.name":   "usecase/${problem}",
  "duration":            30,
  "start_time":          "${start}",
  "end_time":            "${now}"
}
JSON
)"

    # 2. Pipeline run + 6 tasks (matches CI/CD Observability app schema)
    local rid=$(( 20000 + i ))
    local pid="astroshop-release"
    local pname="Astroshop release pipeline"
    sendPipelineEvent "$pid" "$rid" "$pname" "$outcome" main Otel-App/astroshop demo-runner 240
    sendTaskEvent "${rid}-build"     "build"          "success"   "$pid" "$rid" "$pname" main  45
    sendTaskEvent "${rid}-deploy"    "deploy-staging" "success"   "$pid" "$rid" "$pname" main  60
    sendTaskEvent "${rid}-loadtest"  "loadtest"       "success"   "$pid" "$rid" "$pname" main 120
    sendTaskEvent "${rid}-guardian"  "srg-evaluate"   "$outcome"  "$pid" "$rid" "$pname" main  15
    if [ "$verdict" = "pass" ]; then
      sendTaskEvent "${rid}-promote"  "promote-prod"  "success"  "$pid" "$rid" "$pname" main 30
    else
      sendTaskEvent "${rid}-rollback" "rollback"      "success"  "$pid" "$rid" "$pname" main 20
    fi

    # 3. SRG verdict bizevent (what the guardian writes)
    runDeploymentValidation "$version" staging "$problem"
  done
  printInfo "Done. Verify in Dynatrace: 1 pass (1.12.0) + 3 fail (1.12.1/2/3)"
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
  printInfo "Phases: dynatrace operator + apponly → astroshop → gitlab → seed repos"
  printInfo "        → dtctl + monaco → vault credentials → loadgen → 4 release rolls"
  printInfo "Total time: ~20-25 minutes"

  # 1. Dynatrace operator + AppOnly monitoring (so OneAgent + traces flow)
  if [ -n "$DT_OPERATOR_TOKEN" ] && [ -n "$DT_INGEST_TOKEN" ]; then
    dynatraceDeployOperator   || printWarn "dynatrace operator install failed (non-fatal)"
    deployApplicationMonitoring || printWarn "apponly monitoring failed (non-fatal)"
  else
    printWarn "DT_OPERATOR_TOKEN / DT_INGEST_TOKEN not set — skipping Dynatrace operator"
  fi

  # 2. Astroshop, GitLab, repos, tooling.
  # `deployApp astroshop` ships static yaml with the framework's
  # `dynatrace-demoability/docker/astroshop:af0271f-*` images. The
  # workshop story relies on the `shinojosa/astroshop:1.12.X-*`
  # variants — same base code but with deliberately-broken builds for
  # 1.12.1/2/3. We re-roll to 1.12.0 right after the framework
  # deploys so the cluster ALWAYS starts from the workshop's
  # baseline.
  deployApp astroshop          || { printError "astroshop deploy failed"; return 1; }
  printInfoSection "Re-rolling Astroshop to workshop baseline 1.12.0"
  rollAstroshopRelease 1.12.0 none || printWarn "baseline roll failed (non-fatal)"
  installGitlab                || { printError "gitlab install failed"; return 1; }
  seedGitlabRepos              || { printError "gitlab seed failed"; return 1; }
  installDtctl                 || printWarn "dtctl install failed (non-fatal)"
  installMonaco                || printWarn "monaco install failed (non-fatal)"
  applyMonacoConfig            || printWarn "monaco apply failed (non-fatal — likely no DT_PLATFORM_TOKEN)"
  createWorkshopCredentials    || printWarn "credential vault setup failed (non-fatal)"
  deployLoadgenerator          || printWarn "loadgen deploy failed (non-fatal)"

  # 3. Roll the four releases so the SRG + dashboards have cross-release data
  if kubectl get ns "$ASTROSHOP_NAMESPACE" >/dev/null 2>&1 && [ -n "$DT_API_TOKEN" ]; then
    printInfoSection "Rolling the four release variants (1.12.0 / 1 / 2 / 3)"
    local pair
    for pair in "1.12.0 none" "1.12.1 cpu" "1.12.2 memory" "1.12.3 nplusone"; do
      set -- $pair
      rollAstroshopRelease "$1" "$2" || printWarn "  roll of $1 failed (non-fatal)"
      sleep 60   # let each release accumulate ~1 minute of traffic
    done
  else
    printWarn "Astroshop ns or DT_API_TOKEN not present — skipping release rolls"
  fi

  printInfoSection "Workshop bootstrap complete"
  printInfo "GitLab:   http://gitlab.$(detectIP).${MAGIC_DOMAIN:-sslip.io}"
  printInfo "Astroshop: $(getAppURL astroshop 2>/dev/null || echo 'see printGreeting')"
  printInfo "Tenant:   ${DT_ENVIRONMENT:-<not configured>}"
  printInfo ""
  printInfo "Try: 'rollAstroshopRelease 1.12.1 cpu' to roll a release manually"
  printInfo "Or:  'seedWorkshopReleases' to replay all 4 variants"
}

# createWorkshopCredentials — make sure the credential vault has the
# 'hot-session-token' entry the monaco smoketest workflow expects.
# Idempotent: skipped if it already exists.
createWorkshopCredentials(){
  if [ -z "$DT_API_TOKEN" ] || [ -z "$DT_TENANT_URL" ]; then
    printWarn "credentialVault setup requires DT_API_TOKEN + DT_TENANT_URL — skipping"
    return 0
  fi
  printInfoSection "Ensuring 'hot-session-token' credential exists in the vault"
  local existing
  existing=$(curl -sk "${DT_TENANT_URL%/}/api/v2/credentials?name=hot-session-token" \
    -H "Authorization: Api-Token $DT_API_TOKEN" \
    | jq -r '.credentials[0].id // empty')
  if [ -n "$existing" ]; then
    printInfo "Credential already exists: $existing"
    return 0
  fi
  local resp
  resp=$(curl -sk -X POST "${DT_TENANT_URL%/}/api/v2/credentials" \
    -H "Authorization: Api-Token $DT_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"hot-session-token\",\"description\":\"Workshop session token for the SRG smoketest workflow\",\"type\":\"TOKEN\",\"scope\":\"ALL\",\"token\":\"${DT_API_TOKEN}\",\"ownerAccessOnly\":false}")
  local id
  id=$(echo "$resp" | jq -r '.id // empty')
  if [ -n "$id" ]; then
    printInfo "Credential created: $id"
  else
    printWarn "Credential creation failed: $(echo "$resp" | head -c 200)"
  fi
}
