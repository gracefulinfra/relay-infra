# shellcheck shell=bash disable=SC2034 # the settings below are used by the scripts that source this file
# Shared by the scripts/portability/*.sh scripts. Source it; don't execute it.
#
# A run is one export → restore → verify between two environments. Its evidence (step timings, bytes,
# manual steps, manifest, encrypted secrets bundle) is kept in $RUN_DIR, outside git; report.sh renders
# it to Markdown. Every provider detail comes from envs/<env>/env.sh and the overlays.
#
#   FROM    source environment (default local)
#   TO      target environment (default local-b)
#   RUN_ID  run identifier (default: the latest run; export.sh starts a new one)
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require kubectl jq curl

FROM=${FROM:-local}
TO=${TO:-local-b}
[ -f "$REPO_ROOT/envs/$FROM/env.sh" ] || die "no envs/$FROM/env.sh"
[ -f "$REPO_ROOT/envs/$TO/env.sh" ] || die "no envs/$TO/env.sh"
PORTABILITY_HOME=$RELAY_HOME/portability
AGE_KEY=${RELAY_AGE_KEY:-$PORTABILITY_HOME/age.key}
# Where export.sh leaves the manifest and the secrets bundle on the target's storage.
TARGET_RUN_PREFIX=relay-backups/portability
# The synthetic Phase 0 dataset (seed.sh).
MEDIA_OBJECTS=${MEDIA_OBJECTS:-64}
MEDIA_OBJECT_MIB=${MEDIA_OBJECT_MIB:-16}
EPISODE_ROWS=${EPISODE_ROWS:-10000}
# PostgreSQL clusters that are backed up and restored: namespace/cluster.
PG_CLUSTERS=(relay-db/relay keycloak/keycloak-db)
# Buckets copied to the target, with the key prefix to copy ("" = all).
# relay-logs is not copied: logs stay with the environment that wrote them.
COPY_BUCKETS=(relay-media relay-feeds relay-backups:cnpg/)

ctx_of() { printf 'k3d-%s' "$(env_var "$1" CLUSTER_NAME)"; }
kc_env() { # kc_env <env> kubectl args...
  local env=$1
  shift
  kubectl --context "$(ctx_of "$env")" "$@"
}

run_dir_for() {
  local id=$1
  printf '%s/runs/%s' "$PORTABILITY_HOME" "$id"
}
use_run() { # use_run [new]: sets RUN_ID and RUN_DIR
  if [ "${1:-}" = new ]; then
    RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
  elif [ -z "${RUN_ID:-}" ]; then
    [ -L "$PORTABILITY_HOME/latest" ] || die "no run yet: start one with scripts/portability/export.sh"
    RUN_ID=$(basename "$(readlink "$PORTABILITY_HOME/latest")")
  fi
  RUN_DIR=$(run_dir_for "$RUN_ID")
  mkdir -p "$RUN_DIR"
  chmod 700 "$RELAY_HOME" "$PORTABILITY_HOME" "$PORTABILITY_HOME/runs" 2>/dev/null || true
  ln -sfn "runs/$RUN_ID" "$PORTABILITY_HOME/latest"
  touch "$RUN_DIR/steps.tsv" "$RUN_DIR/manual.tsv" "$RUN_DIR/facts.tsv"
  export RUN_ID RUN_DIR
}

# step <phase> <name> <command...>: runs a step, and records its wall-clock time and outcome in
# $RUN_DIR/steps.tsv. A step that transfers data records its bytes with `record_bytes`.
step() {
  local phase=$1 name=$2 t rc bytes
  shift 2
  log "[$phase] $name"
  t=$(now_s)
  STEP_BYTES_FILE=$(mktemp)
  # Run the step in a subshell with errexit on. Calling it as `"$@" || rc=$?` would switch errexit
  # off inside the whole function (bash ignores -e in a || list), so a failed command mid-step, such as
  # a cluster that was never created, was silently ignored (the first CI rehearsal, 2026-09-28).
  set +e
  (
    set -e
    "$@"
  )
  rc=$?
  set -e
  bytes=$(cat "$STEP_BYTES_FILE")
  rm -f "$STEP_BYTES_FILE"
  printf '%s\t%s\t%s\t%s\t%s\n' "$phase" "$name" "$(($(now_s) - t))" "$bytes" \
    "$([ "$rc" = 0 ] && echo ok || echo "failed ($rc)")" >>"$RUN_DIR/steps.tsv"
  [ "$rc" = 0 ] || die "[$phase] $name failed"
}
# record_bytes <n>: adds to the current step's byte count (a file, because steps run in a subshell).
record_bytes() { echo $(($(cat "$STEP_BYTES_FILE" 2>/dev/null || echo 0) + $1)) >"$STEP_BYTES_FILE"; }

# manual_step <phase> <what the operator had to do by hand>. The target is zero; each one is reported.
manual_step() { printf '%s\t%s\n' "$1" "$2" >>"$RUN_DIR/manual.tsv"; }

# note <key> <value>: run facts for the report (commits, versions, sizes).
note() {
  local f=$RUN_DIR/facts.tsv
  awk -F'\t' -v k="$1" '$1 != k' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  printf '%s\t%s\n' "$1" "$2" >>"$f"
}

# psql_env <env> <namespace/cluster> <db> [psql args...]: psql on the cluster's primary, SQL on stdin.
psql_env() {
  local env=$1 nc=$2 db=$3 ns cluster primary
  shift 3
  ns=${nc%%/*} cluster=${nc#*/}
  primary=$(kc_env "$env" -n "$ns" get cluster "$cluster" -o jsonpath='{.status.currentPrimary}')
  [ -n "$primary" ] || die "$env: no primary for $nc"
  kc_env "$env" -n "$ns" exec -i "$primary" -c postgres -- psql -X -q -v ON_ERROR_STOP=1 -d "$db" "$@"
}

# Episode table digest: identical data gives an identical digest, on any cluster.
EPISODES_DIGEST_SQL="SELECT count(*) || ' ' || md5(coalesce(string_agg(guid::text || '|' || title || '|' ||
  published_at::text || '|' || media_key || '|' || media_sha256, E'\n' ORDER BY guid), ''))
  FROM portability.episodes"

# rclone in a container, for bulk transfers inside a cluster (port-forwards drop on multi-GB copies).
# The tag must match RCLONE_VERSION in scripts/lib.sh.
RCLONE_IMAGE=${RCLONE_IMAGE:-docker.io/rclone/rclone:1.75.1@sha256:45401ad7410db1d67ffdb58e19059ad20b0d8e0285a60e38bbec55cc1019c7a5}
JOB_NAMESPACE=relay-portability

# cluster_network <env>: the Docker network of the env's k3d cluster.
cluster_network() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' \
    "k3d-$(env_var "$1" CLUSTER_NAME)-server-0" | head -1
}

# rclone_job <run-env> <name> <remote>=<env>... -- <shell script>
# Runs the script with rclone in a Job in <run-env>'s cluster. Each remote points at an env's S3 as that
# env's admin identity, by the address pods use (S3_CLUSTER_ENDPOINT). Another env's external endpoint is
# made reachable with `external-s3.sh attach` and a hostAlias. Lines the script prints with a leading
# "@@ " are its results: they go to $RUN_DIR/jobs/<name>.out; the full log to $RUN_DIR/jobs/<name>.log.
# Call it directly, not in $(...), so a failure stops the calling script.
rclone_job() {
  local run_env=$1 name=$2 vars="" aliases="[]" ca="" arg remote env endpoint
  shift 2
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    arg=$1 remote=${1%%=*} env=${1#*=}
    shift
    endpoint=$(env_var "$env" S3_CLUSTER_ENDPOINT)
    vars+=$(s3_remote_env "$remote" "$env" "$endpoint")$'\n'
    if [ "$(env_var "$env" S3_MODE)" = external ]; then
      ca=$(env_var "$env" S3_CA_FILE)
      if [ "$env" != "$run_env" ]; then
        local ip host
        ip=$(RELAY_ENV=$env "$REPO_ROOT/scripts/external-s3.sh" attach "$(cluster_network "$run_env")")
        host=${endpoint#https://}
        aliases=$(jq -c --arg ip "$ip" --arg h "${host%%:*}" '. + [{ip: $ip, hostnames: [$h]}]' <<<"$aliases")
      fi
    elif [ "$env" != "$run_env" ]; then
      die "$arg: $env's S3 is inside its own cluster and not reachable from $run_env"
    fi
  done
  shift
  local script=$1 job="portability-$name" log="$RUN_DIR/jobs/$name.log"
  mkdir -p "$RUN_DIR/jobs"
  kc_env "$run_env" create namespace "$JOB_NAMESPACE" --dry-run=client -o yaml | kc_env "$run_env" apply -f - >/dev/null
  kc_env "$run_env" -n "$JOB_NAMESPACE" delete job "$job" --ignore-not-found >/dev/null
  {
    printf '%s' "$vars" | grep -v '^$'
    echo "RCLONE_CONFIG=/dev/null"
    [ -z "$ca" ] || echo "RCLONE_CA_CERT=/etc/relay-s3/ca.crt"
  } | kc_env "$run_env" -n "$JOB_NAMESPACE" create secret generic "$job" --from-env-file=/dev/stdin \
    --dry-run=client -o yaml | kc_env "$run_env" apply -f - >/dev/null
  kc_env "$run_env" -n "$JOB_NAMESPACE" create secret generic "$job-ca" \
    --from-file=ca.crt="${ca:-/dev/null}" --dry-run=client -o yaml | kc_env "$run_env" apply -f - >/dev/null
  jq -n --arg job "$job" --arg ns "$JOB_NAMESPACE" --arg image "$RCLONE_IMAGE" --arg script "$script" \
    --argjson aliases "$aliases" '{
    apiVersion: "batch/v1", kind: "Job",
    metadata: {name: $job, namespace: $ns, labels: {"relay.dev/portability": "true"}},
    spec: {backoffLimit: 0, activeDeadlineSeconds: 3600, template: {spec: {
      restartPolicy: "Never", hostAliases: $aliases, automountServiceAccountToken: false,
      securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{name: "rclone", image: $image, command: ["sh", "-euc", $script],
        envFrom: [{secretRef: {name: $job}}], env: [{name: "HOME", value: "/tmp"}],
        resources: {requests: {cpu: "100m", memory: "128Mi"}, limits: {memory: "512Mi"}},
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}},
        volumeMounts: [{name: "tmp", mountPath: "/tmp"}, {name: "ca", mountPath: "/etc/relay-s3", readOnly: true}]}],
      volumes: [{name: "tmp", emptyDir: {sizeLimit: "2Gi"}}, {name: "ca", secret: {secretName: ($job + "-ca")}}]}}}}' |
    kc_env "$run_env" apply -f - >/dev/null
  local phase="" status
  while :; do
    status=$(kc_env "$run_env" -n "$JOB_NAMESPACE" get job "$job" -o json) || die "job $job disappeared"
    phase=$(jq -r '[.status.conditions[]? | select(.status == "True") | .type]
      | map(select(. == "Complete" or . == "Failed")) | first // ""' <<<"$status")
    [ -n "$phase" ] && break
    sleep 3
  done
  kc_env "$run_env" -n "$JOB_NAMESPACE" logs "job/$job" >"$log" 2>&1 || true
  kc_env "$run_env" -n "$JOB_NAMESPACE" delete job "$job" --wait=false >/dev/null
  kc_env "$run_env" -n "$JOB_NAMESPACE" delete secret "$job" "$job-ca" >/dev/null
  if [ "$phase" != Complete ]; then
    tail -20 "$log" >&2
    die "job $job failed (log: $log)"
  fi
  sed -n 's/^@@ //p' "$log" >"$RUN_DIR/jobs/$name.out"
}

# rclone_bytes: bytes transferred, from the final stats line of `rclone ... --use-json-log -v` on stdin.
rclone_bytes() { grep '^{' | jq -rs '[.[] | select(.stats != null) | .stats.bytes] | last // 0'; }

cleanup_s3() { s3_close_all; }
trap cleanup_s3 EXIT
