# shellcheck shell=bash
# Shared helpers for the relay-infra scripts. Source it; don't execute it.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT

# Local state that must survive `make down`, such as the local CA, lives outside the repo so worktrees share it.
RELAY_HOME=${RELAY_HOME:-$HOME/.relay-local}
RELAY_ENV=${RELAY_ENV:-local}
# Per-environment settings for the scripts (cluster name, domain, S3 access) live next to the overlay in
# envs/<env>/env.sh, never in the scripts. Values already in the environment win, except those a parent
# script exported for another env (a portability run calls scripts for both of its envs).
if [ -n "${RELAY_LOADED_ENV:-}" ] && [ "$RELAY_LOADED_ENV" != "$RELAY_ENV" ]; then
  unset KUBE_CONTEXT
  while read -r v; do unset "$v"; done < <(sed -n 's/^: "\${\([A-Z0-9_]*\):=.*/\1/p' "$REPO_ROOT/envs/$RELAY_LOADED_ENV/env.sh" 2>/dev/null)
fi
RELAY_LOADED_ENV=$RELAY_ENV
export RELAY_LOADED_ENV
if [ -f "$REPO_ROOT/envs/$RELAY_ENV/env.sh" ]; then
  # shellcheck source=envs/local/env.sh
  source "$REPO_ROOT/envs/$RELAY_ENV/env.sh"
fi
CLUSTER_NAME=${CLUSTER_NAME:-relay}
KUBE_CONTEXT=${KUBE_CONTEXT:-k3d-${CLUSTER_NAME}}
TOOLS_BIN=${TOOLS_BIN:-$REPO_ROOT/.local/bin}
export CLUSTER_NAME KUBE_CONTEXT RELAY_HOME RELAY_ENV TOOLS_BIN

# env_var <env> <VAR>: prints VAR as envs/<env>/env.sh sets it, without touching this shell's settings.
env_var() {
  env -i HOME="$HOME" PATH="$PATH" RELAY_HOME="$RELAY_HOME" REPO_ROOT="$REPO_ROOT" \
    bash -c 'source "$REPO_ROOT/envs/$1/env.sh" && printf "%s" "${!2:-}"' _ "$1" "$2"
}

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
# renovate: datasource=github-releases depName=rclone/rclone
RCLONE_VERSION=${RCLONE_VERSION:-1.75.1}
# renovate: datasource=github-releases depName=FiloSottile/age
AGE_VERSION=${AGE_VERSION:-1.3.2}
rclone() { "$(go_tool rclone "github.com/rclone/rclone@v$RCLONE_VERSION")" "$@"; }
age() { "$(go_tool age "filippo.io/age/cmd/age@v$AGE_VERSION")" "$@"; }
age_keygen() { "$(go_tool age-keygen "filippo.io/age/cmd/age-keygen@v$AGE_VERSION")" "$@"; }

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

# now_s prints the current Unix time in seconds; elapsed <start> prints "Xm Ys".
now_s() { date +%s; }
elapsed() {
  local s=$(($(now_s) - $1))
  printf '%dm %02ds' $((s / 60)) $((s % 60))
}

# S3 identities: one per consumer, each limited to its bucket. `admin` is for operators, the smoke test and
# the portability scripts. name|bucket ("*" = all buckets, admin rights)
S3_IDENTITIES=("admin|*" "cnpg|relay-backups" "workflows|relay-media" "otel|relay-logs")

# seaweedfs_iam_config: reads {"<name>": {"access_key_id", "secret_access_key"}, ...} on stdin and
# prints the SeaweedFS S3 IAM config granting each identity in S3_IDENTITIES its bucket.
seaweedfs_iam_config() {
  local creds entry name bucket
  creds=$(cat)
  for entry in "${S3_IDENTITIES[@]}"; do
    name=${entry%%|*} bucket=${entry#*|}
    jq -n --arg name "$name" --arg bucket "$bucket" --argjson c "$(jq --arg n "$name" '.[$n]' <<<"$creds")" \
      '{name: $name, credentials: [{accessKey: $c.access_key_id, secretKey: $c.secret_access_key}],
        actions: (if $bucket == "*" then ["Admin", "Read", "Write", "List", "Tagging"]
                  else ["Read:\($bucket)", "Write:\($bucket)", "List:\($bucket)", "Tagging:\($bucket)"] end)}'
  done | jq -cs '{identities: .}'
}

# S3 access for rclone, configured only through RCLONE_CONFIG_<REMOTE>_* variables (no rclone config
# file, so no credentials on disk). Everything comes from envs/<env>/env.sh and the env's secrets.
#
# s3_remote_env <remote> <env> <endpoint>: prints the variables that point <remote> at <env>'s S3 as
# its admin identity, one NAME=value per line.
s3_remote_env() {
  local remote=$1 env=$2 endpoint=$3 R ak sk
  R=RCLONE_CONFIG_$(tr '[:lower:]-' '[:upper:]_' <<<"$remote")
  case $(env_var "$env" S3_MODE) in
  external)
    local creds
    creds=$(env_var "$env" S3_STATE_DIR)/identities.json
    [ -s "$creds" ] || die "no S3 credentials for $env in $creds (RELAY_ENV=$env scripts/external-s3.sh up)"
    ak=$(jq -r .admin.access_key_id "$creds")
    sk=$(jq -r .admin.secret_access_key "$creds")
    ;;
  in-cluster)
    local secret
    secret=$(kubectl --context "k3d-$(env_var "$env" CLUSTER_NAME)" -n relay-secret-source get secret s3-admin -o json) ||
      die "cannot read $env's s3-admin secret: is its cluster running?"
    ak=$(jq -r '.data.access_key_id | @base64d' <<<"$secret")
    sk=$(jq -r '.data.secret_access_key | @base64d' <<<"$secret")
    ;;
  *) die "envs/$env/env.sh sets no known S3_MODE" ;;
  esac
  printf '%s\n' "${R}_TYPE=s3" "${R}_PROVIDER=SeaweedFS" "${R}_REGION=us-east-1" "${R}_FORCE_PATH_STYLE=true" \
    "${R}_ENDPOINT=$endpoint" "${R}_ACCESS_KEY_ID=$ak" "${R}_SECRET_ACCESS_KEY=$sk"
}

# s3_open <remote> <env>: points the rclone remote <remote> at <env>'s S3 from this machine. In-cluster
# S3 is reached through a port-forward (fine for small objects; bulk copies run in the cluster, see
# scripts/portability/common.sh) that s3_close_all stops.
S3_PORT_FORWARDS=()
s3_open() {
  local remote=$1 env=$2 endpoint line
  case $(env_var "$env" S3_MODE) in
  external)
    endpoint=$(env_var "$env" S3_ENDPOINT)
    # rclone takes one CA bundle for every TLS connection; only external endpoints use TLS here.
    export RCLONE_CA_CERT
    RCLONE_CA_CERT=$(env_var "$env" S3_CA_FILE)
    ;;
  in-cluster)
    local port
    port=$((20000 + RANDOM % 10000))
    kubectl --context "k3d-$(env_var "$env" CLUSTER_NAME)" -n "$(env_var "$env" S3_NAMESPACE)" \
      port-forward "svc/$(env_var "$env" S3_SERVICE)" "$port:$(env_var "$env" S3_SERVICE_PORT)" >/dev/null 2>&1 &
    S3_PORT_FORWARDS+=($!)
    endpoint=http://127.0.0.1:$port
    for _ in $(seq 1 30); do
      [ "$(curl -s -o /dev/null -w '%{http_code}' "$endpoint/" || true)" = 403 ] && break
      sleep 1
    done
    ;;
  esac
  local vars
  vars=$(s3_remote_env "$remote" "$env" "$endpoint") || exit 1
  export RCLONE_CONFIG=/dev/null
  while IFS= read -r line; do export "${line?}"; done <<<"$vars"
}
s3_close_all() {
  local pid
  for pid in "${S3_PORT_FORWARDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  S3_PORT_FORWARDS=()
}

# rand [n]: n random alphanumeric characters (default 32).
rand() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | cut -c "1-${1:-32}"; }
