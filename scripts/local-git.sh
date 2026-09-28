#!/usr/bin/env bash
# LOCAL_GIT=1 support: an in-cluster git server that Argo CD reads instead of GitHub, so you can
# iterate without pushing.
#   scripts/local-git.sh up     build the server image, push it to the k3d registry, deploy it
#   scripts/local-git.sh sync   push a snapshot of the working tree (tracked + untracked, honouring
#                               .gitignore) to branch `local` and ask Argo CD to refresh
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require docker kubectl git envsubst

REGISTRY_HOST_PORT=${REGISTRY_HOST_PORT:?envs/$RELAY_ENV/env.sh sets no REGISTRY_HOST_PORT}
REGISTRY_NAME=${REGISTRY_NAME:?envs/$RELAY_ENV/env.sh sets no REGISTRY_NAME}
LOCAL_BRANCH=${LOCAL_BRANCH:-local}
export LOCAL_GIT_URL=http://git-server.relay-git.svc.cluster.local/relay-infra.git

up() {
  local ctx="$REPO_ROOT/bootstrap/local-git"
  local tag
  tag=$(cat "$ctx/Dockerfile" "$ctx/lighttpd.conf" "$ctx/entrypoint.sh" | git hash-object --stdin | cut -c1-12)
  log "building relay-git-server:$tag"
  docker build -q -t "localhost:$REGISTRY_HOST_PORT/relay-git-server:$tag" "$ctx" >/dev/null
  docker push -q "localhost:$REGISTRY_HOST_PORT/relay-git-server:$tag" >/dev/null
  GIT_SERVER_IMAGE="$REGISTRY_NAME:$REGISTRY_HOST_PORT/relay-git-server:$tag" envsubst '${GIT_SERVER_IMAGE}' \
    <"$ctx/git-server.yaml" | kc apply -f - >/dev/null
  kc -n relay-git rollout status deploy/git-server --timeout=180s >/dev/null
  log "git server ready at $LOCAL_GIT_URL"
  sync
}

sync() {
  local tmp pf_pid=""
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  # Build a commit of the working tree with a throwaway index so the real index and HEAD are untouched.
  local tree commit
  GIT_INDEX_FILE="$tmp/index" git -C "$REPO_ROOT" read-tree HEAD
  GIT_INDEX_FILE="$tmp/index" git -C "$REPO_ROOT" add -A
  tree=$(GIT_INDEX_FILE="$tmp/index" git -C "$REPO_ROOT" write-tree)
  # A shallow clone (CI's actions/checkout) cannot push a commit whose parent history is missing
  # ("shallow update not allowed"), and Argo CD only needs the tree, so the snapshot has no parent there.
  local parent=(-p HEAD)
  [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository)" = true ] && parent=()
  commit=$(git -C "$REPO_ROOT" commit-tree "$tree" "${parent[@]}" -m "local snapshot of $(git -C "$REPO_ROOT" rev-parse --short HEAD)")

  local port=${LOCAL_GIT_PORT:-18080}
  kc -n relay-git port-forward svc/git-server "$port:80" >/dev/null 2>&1 &
  pf_pid=$!
  for _ in $(seq 1 30); do
    curl -fsS -o /dev/null "http://127.0.0.1:$port/relay-infra.git/info/refs?service=git-upload-pack" 2>/dev/null && break
    sleep 0.5
  done
  git -C "$REPO_ROOT" push -q -f "http://127.0.0.1:$port/relay-infra.git" "${commit}:refs/heads/$LOCAL_BRANCH"
  kill "$pf_pid" 2>/dev/null || true
  log "pushed working-tree snapshot $(git -C "$REPO_ROOT" rev-parse --short "$commit") to $LOCAL_BRANCH"

  if kc -n argocd get application relay-root >/dev/null 2>&1; then
    kc -n argocd annotate application relay-root argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  fi
}

case ${1:-} in
  up) up ;;
  sync) sync ;;
  *) die "usage: $0 up|sync" ;;
esac
