#!/usr/bin/env bash
# Waits until relay-root and every Application it created are Synced and Healthy.
# Usage: scripts/wait-apps.sh [timeout-seconds] [since-unix-time]
# With since-unix-time, a status only counts if Argo CD reconciled it after that time. After a cluster
# restart, the stored status predates the restart and says nothing about the pods.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require kubectl jq

timeout=${1:-900}
since=${2:-0}
start=$(now_s)
last_report=0
last_refresh=0
while :; do
  apps=$(kc -n argocd get applications.argoproj.io -o json 2>/dev/null || echo '{"items":[]}')
  pending=$(jq -r --argjson since "$since" '.items[]
    | select(.status.sync.status != "Synced" or .status.health.status != "Healthy"
        or ((.status.reconciledAt // "1970-01-01T00:00:00Z") | fromdateiso8601) < $since)
    | "\(.metadata.name)=\(.status.sync.status // "?")/\(.status.health.status // "?")"' <<<"$apps")
  root_ok=$(jq -r '[.items[] | select(.metadata.name == "relay-root")] | length' <<<"$apps")
  if [ "$root_ok" = 1 ] && [ -z "$pending" ]; then
    log "all $(jq '.items | length' <<<"$apps") Applications are Synced/Healthy ($(elapsed "$start"))"
    exit 0
  fi
  now=$(now_s)
  if [ $((now - start)) -ge "$timeout" ]; then
    kc -n argocd get applications.argoproj.io >&2 || true
    die "timed out after ${timeout}s; not ready: $(tr '\n' ' ' <<<"$pending")"
  fi
  # Stale statuses would otherwise wait for the next periodic reconcile (timeout.reconciliation).
  if [ "$since" -gt 0 ] && [ $((now - last_refresh)) -ge 20 ]; then
    for app in $(jq -r --argjson since "$since" '.items[]
      | select(((.status.reconciledAt // "1970-01-01T00:00:00Z") | fromdateiso8601) < $since) | .metadata.name' <<<"$apps"); do
      kc -n argocd annotate application "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
    done
    last_refresh=$now
  fi
  if [ $((now - last_report)) -ge 30 ]; then
    log "waiting ($(elapsed "$start")): $(tr '\n' ' ' <<<"${pending:-relay-root not created yet}")"
    last_report=$now
  fi
  sleep 5
done
