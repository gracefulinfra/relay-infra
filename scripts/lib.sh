# shellcheck shell=bash
# Shared helpers for the relay-infra scripts. Source it; don't execute it.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT

CLUSTER_NAME=${CLUSTER_NAME:-relay}
KUBE_CONTEXT=${KUBE_CONTEXT:-k3d-${CLUSTER_NAME}}
# Local state that must survive `make down`, such as the local CA, lives outside the repo so worktrees share it.
RELAY_HOME=${RELAY_HOME:-$HOME/.relay-local}
TOOLS_BIN=${TOOLS_BIN:-$REPO_ROOT/.local/bin}
export CLUSTER_NAME KUBE_CONTEXT RELAY_HOME TOOLS_BIN

# Pinned CLI tools that are installed with `go install` into .local/bin.
# renovate: datasource=github-releases depName=mikefarah/yq
YQ_VERSION=${YQ_VERSION:-4.53.6}
# renovate: datasource=github-releases depName=yannh/kubeconform
KUBECONFORM_VERSION=${KUBECONFORM_VERSION:-0.8.0}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

require() {
  local missing=()
  for tool in "$@"; do command -v "$tool" >/dev/null || missing+=("$tool"); done
  if [ ${#missing[@]} -gt 0 ]; then die "missing tools: ${missing[*]} (see README prerequisites)"; fi
}

# go_tool <binary> <module path>@<version>: installs a pinned Go tool once and prints its path.
go_tool() {
  local bin=$1 pkg=$2 version=${2##*@}
  local target="$TOOLS_BIN/$bin-$version"
  if [ ! -x "$target" ]; then
    require go
    mkdir -p "$TOOLS_BIN"
    log "installing $pkg"
    GOBIN="$TOOLS_BIN" go install "$pkg" >&2
    mv "$TOOLS_BIN/$bin" "$target"
  fi
  printf '%s' "$target"
}

yq() { "$(go_tool yq "github.com/mikefarah/yq/v4@v$YQ_VERSION")" "$@"; }
kubeconform() { "$(go_tool kubeconform "github.com/yannh/kubeconform/cmd/kubeconform@v$KUBECONFORM_VERSION")" "$@"; }

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

# now_s prints the current Unix time in seconds; elapsed <start> prints "Xm Ys".
now_s() { date +%s; }
elapsed() {
  local s=$(($(now_s) - $1))
  printf '%dm %02ds' $((s / 60)) $((s % 60))
}

# rand [n]: n random alphanumeric characters (default 32).
rand() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | cut -c "1-${1:-32}"; }
