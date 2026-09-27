#!/usr/bin/env bash
# Restores an export into the target environment ($TO), from the target's own storage:
#   1. fetches the run's manifest and encrypted secrets bundle from s3://relay-backups/portability/<run>/
#      and checks the inventories against the manifest;
#   2. stops the source cluster when both would not fit on this machine (STOP_SOURCE=1, the default);
#   3. bootstraps the target cluster through GitOps (scripts/up.sh with RELAY_ENV=$TO). The carried
#      secrets are imported before Argo CD syncs, and relay-root carries each PostgreSQL cluster's
#      recovery target (the export's backup, recovered to the end of that backup);
#   4. waits for both PostgreSQL clusters to finish bootstrap.recovery;
#   5. hashes every copied object on the target and checks counts and SHA-256 against the manifest.
#
# Usage: FROM=local TO=local-b scripts/portability/restore.sh   (RUN_ID, default the latest run;
#        LOCAL_GIT=1 and REVISION pass through to scripts/up.sh)
set -euo pipefail
# shellcheck source=scripts/portability/common.sh
source "$(dirname "$0")/common.sh"
require age git k3d

use_run
restore_dir=$RUN_DIR/restore
mkdir -p "$restore_dir"
STOP_SOURCE=${STOP_SOURCE:-1}

fetch_manifest() {
  s3_open dst "$TO"
  rclone copy "dst:$TARGET_RUN_PREFIX/$RUN_ID" "$restore_dir"
  [ -s "$restore_dir/manifest.json" ] || die "no manifest at $TARGET_RUN_PREFIX/$RUN_ID on $TO"
  local b want got
  for b in $(jq -r '.buckets | keys[]' "$restore_dir/manifest.json"); do
    want=$(jq -r --arg b "$b" '.buckets[$b].inventory_sha256' "$restore_dir/manifest.json")
    got=$(shasum -a 256 "$restore_dir/$b.sha256" | cut -d' ' -f1)
    [ "$want" = "$got" ] || die "inventory $b.sha256 does not match the manifest"
  done
  note relay_infra_commit_restore "$(git -C "$REPO_ROOT" rev-parse HEAD)"
  note relay_infra_dirty_restore "$(git -C "$REPO_ROOT" status --porcelain | wc -l | tr -d ' ') changed paths"
}

stop_source() {
  local c
  c=$(env_var "$FROM" CLUSTER_NAME)
  if k3d cluster list -o json | jq -e --arg c "$c" '.[] | select(.name == $c and .serversRunning > 0)' >/dev/null; then
    k3d cluster stop "$c" >/dev/null
    log "stopped cluster $c (the laptop profile fits one platform at a time)"
  fi
}

# The recovery target is a run-time input: Kustomize patches that relay-root applies to envs/$TO.
recovery_patches() {
  jq -r '.recovery_point[] | "- target: {kind: Cluster, name: \(.cluster | split("/")[1]), namespace: \(.cluster | split("/")[0])}
  patch: |-
    - op: add
      path: /spec/bootstrap/recovery/recoveryTarget
      value: {backupID: \"\(.backup_id)\", targetImmediate: true}"' "$restore_dir/manifest.json" >"$restore_dir/root-app-patches.yaml"
}

bootstrap() {
  recovery_patches
  RELAY_ENV=$TO RELAY_SECRETS_BUNDLE="$restore_dir/secrets.age" ROOT_APP_PATCHES="$restore_dir/root-app-patches.yaml" \
    "$REPO_ROOT/scripts/up.sh" 2>&1 | tee "$RUN_DIR/up-$TO.log" >&2
  note argocd_revision_restore "$(kc_env "$TO" -n argocd get application relay-root -o jsonpath='{.status.sync.revision}')"
}

wait_recovery() {
  local nc ns cluster
  for nc in $(jq -r '.recovery_point[].cluster' "$restore_dir/manifest.json"); do
    ns=${nc%%/*} cluster=${nc#*/}
    kc_env "$TO" -n "$ns" wait --for=condition=Ready "cluster/$cluster" --timeout=900s >/dev/null ||
      die "$nc did not become Ready: $(kc_env "$TO" -n "$ns" get cluster "$cluster" -o jsonpath='{.status.phase}')"
    note "timeline_$cluster" "$(kc_env "$TO" -n "$ns" get cluster "$cluster" -o jsonpath='{.status.timelineID}')"
  done
}

verify_objects() {
  local script="" b prefix
  for b in $(jq -r '.buckets | keys[]' "$restore_dir/manifest.json"); do
    prefix=$(jq -r --arg b "$b" '.buckets[$b].prefix' "$restore_dir/manifest.json")
    script+="rclone hashsum sha256 --download 'dst:$b/$prefix' | sed 's|^\([0-9a-f]*\)  |@@ $b \1 $prefix|'
"
  done
  rclone_job "$TO" target-inventory dst="$TO" -- "$script"
  local failures=0 missing
  for b in $(jq -r '.buckets | keys[]' "$restore_dir/manifest.json"); do
    awk -v b="$b" '$1 == b {print $2 "  " $3}' "$RUN_DIR/jobs/target-inventory.out" | sort -k2 >"$restore_dir/target-$b.sha256"
    # Every exported object must be on the target with the same SHA-256 (the target may hold more).
    missing=$(comm -23 <(sort "$restore_dir/$b.sha256") <(sort "$restore_dir/target-$b.sha256"))
    if [ -n "$missing" ]; then
      warn "$b: $(wc -l <<<"$missing" | tr -d ' ') objects missing or different on $TO, e.g. $(head -1 <<<"$missing")"
      failures=$((failures + 1))
    fi
    note "objects_$b" "$(wc -l <"$restore_dir/$b.sha256" | tr -d ' ') exported, all present with matching SHA-256 on $TO"
  done
  [ "$failures" = 0 ] || die "object verification failed for $failures bucket(s)"
}

step restore "fetch manifest and secrets bundle from $TO's S3" fetch_manifest
if [ "$STOP_SOURCE" = 1 ]; then step restore "stop the $FROM cluster (laptop capacity)" stop_source; fi
step restore "bootstrap $TO through GitOps (cluster, secrets, Argo CD, platform)" bootstrap
step restore "CNPG bootstrap.recovery to the recovery point" wait_recovery
step restore "object counts and SHA-256 on $TO" verify_objects
log "restore $RUN_ID done"
