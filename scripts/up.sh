#!/usr/bin/env bash
# Creates the local k3d cluster and hands it to Argo CD:
#   1. k3d cluster + local registry ($K3D_CONFIG from envs/$RELAY_ENV/env.sh)
#   2. local secrets (scripts/secrets.sh)
#   3. optional in-cluster git server (LOCAL_GIT=1)
#   4. Argo CD via Helm, with the chart and values from platform/argo-cd/application.yaml
#   5. the relay-root app-of-apps pointing at envs/$RELAY_ENV
#   6. wait until every Application is Synced and Healthy
#
# Environment:
#   RELAY_ENV     overlay to reconcile (default local)
#   LOCAL_GIT=1   serve the working tree from an in-cluster git server instead of GitHub
#   REPO_URL      git URL Argo CD reads (default https://github.com/gracefulinfra/relay-infra.git)
#   REVISION      branch, tag or SHA (default: the current branch if it exists on origin, else main)
#   WAIT_TIMEOUT  seconds to wait for Synced/Healthy (default 900)
#   ROOT_APP_PATCHES  optional YAML list of Kustomize patches for relay-root (spec.source.kustomize.patches),
#                 for run-time inputs that must not be committed, such as a restore's recovery target
#   RELAY_SECRETS_BUNDLE  optional age-encrypted secrets bundle that scripts/secrets.sh imports first
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require docker k3d kubectl helm git envsubst openssl curl

WAIT_TIMEOUT=${WAIT_TIMEOUT:-900}
export RELAY_ENV
start=$(now_s)
timings=()
mark() { timings+=("$(printf '%-24s %s' "$1" "$(elapsed "$2")")"); }

# --- Preflight -----------------------------------------------------------------------------------
docker info >/dev/null 2>&1 || die "Docker is not running"
mem_bytes=$(docker info --format '{{.MemTotal}}')
mem_gib=$((mem_bytes / 1024 / 1024 / 1024))
if [ "$mem_gib" -lt 7 ]; then
  warn "Docker has ${mem_gib} GiB of memory; the laptop profile needs about 7 GiB (see docs/laptop-profile.md)"
fi

# --- 1. Cluster -----------------------------------------------------------------------------------
t=$(now_s)
cluster_started=$t
if k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  log "cluster $CLUSTER_NAME exists; starting it"
  k3d cluster start "$CLUSTER_NAME" >/dev/null
else
  log "creating k3d cluster $CLUSTER_NAME"
  k3d cluster create --config "$REPO_ROOT/${K3D_CONFIG:?envs/$RELAY_ENV/env.sh sets no K3D_CONFIG}" >/dev/null
fi
kc wait --for=condition=Ready node --all --timeout=180s >/dev/null
mark "cluster" "$t"

# --- 2. Secrets -----------------------------------------------------------------------------------
t=$(now_s)
"$REPO_ROOT/scripts/secrets.sh"
mark "secrets" "$t"

# --- 3. Git source --------------------------------------------------------------------------------
t=$(now_s)
if [ "${LOCAL_GIT:-0}" = 1 ]; then
  "$REPO_ROOT/scripts/local-git.sh" up
  REPO_URL=http://git-server.relay-git.svc.cluster.local/relay-infra.git
  REVISION=local
else
  REPO_URL=${REPO_URL:-https://github.com/gracefulinfra/relay-infra.git}
  if [ -z "${REVISION:-}" ]; then
    branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
    if git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      REVISION=$branch
    else
      REVISION=main
    fi
    if [ "$REVISION" != "$branch" ] || [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
      warn "Argo CD reads $REPO_URL@$REVISION, not your working tree. Use LOCAL_GIT=1 to test local changes."
    fi
  fi
fi
export REPO_URL REVISION
mark "git source" "$t"

# --- 4. Argo CD -----------------------------------------------------------------------------------
t=$(now_s)
app="$REPO_ROOT/platform/argo-cd/application.yaml"
chart_repo=$(yq '.spec.source.repoURL' "$app")
chart_version=$(yq '.spec.source.targetRevision' "$app")
values=$(mktemp)
trap 'rm -f "$values"' EXIT
yq '.spec.source.helm.valuesObject' "$app" >"$values"
if helm --kube-context "$KUBE_CONTEXT" status argocd -n argocd >/dev/null 2>&1; then
  log "Argo CD already installed; Argo CD now manages it"
else
  log "installing Argo CD chart $chart_version"
  helm --kube-context "$KUBE_CONTEXT" install argocd argo-cd --repo "$chart_repo" --version "$chart_version" \
    --namespace argocd --create-namespace --values "$values" --wait --timeout 10m >/dev/null
fi
mark "argo cd" "$t"

# --- 5. Root app ----------------------------------------------------------------------------------
t=$(now_s)
log "applying relay-root -> $REPO_URL@$REVISION envs/$RELAY_ENV"
root_app=$(envsubst '${REPO_URL} ${REVISION} ${RELAY_ENV}' <"$REPO_ROOT/bootstrap/root-app.yaml")
if [ -n "${ROOT_APP_PATCHES:-}" ]; then
  log "relay-root carries run-time Kustomize patches from $ROOT_APP_PATCHES"
  root_app=$(PATCHES="$ROOT_APP_PATCHES" yq '.spec.source.kustomize.patches += load(strenv(PATCHES))' <<<"$root_app")
fi
kc apply -f - <<<"$root_app" >/dev/null

# --- 6. Wait --------------------------------------------------------------------------------------
"$REPO_ROOT/scripts/wait-apps.sh" "$WAIT_TIMEOUT" "$cluster_started"
mark "platform sync" "$t"

log "done in $(elapsed "$start")"
printf '  %s\n' "${timings[@]}" >&2
cat >&2 <<EOF

  Argo CD   https://argocd.$DOMAIN   (admin / make argocd-password)
  Trust the local CA once: see README "Trusting the local CA" ($CA_DIR/relay-local-ca.crt)
  Next: scripts/smoke.sh
EOF
