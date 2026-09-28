#!/usr/bin/env bash
# Exports the source environment ($FROM) to the target environment's storage ($TO):
#   1. takes an on-demand CNPG backup of every PostgreSQL cluster. The backups are the recovery point:
#      restore.sh recovers each cluster to exactly the end of its backup;
#   2. writes an 'after-backup' marker and switches WAL, so a restore that overshot the point would show it;
#   3. inventories the objects to copy (SHA-256 of every object, read back from S3) and checks that every
#      object the recovery point needs (base backup files, end-of-backup WAL) is in the inventory;
#   4. copies exactly the inventoried objects to the target's S3 (media and feeds are immutable, so the
#      copy is a superset of what the recovery point references);
#   5. writes the secrets that must travel with the data to an age-encrypted bundle (never in plaintext);
#   6. publishes the manifest, the inventories and the bundle to s3://relay-backups/portability/<run>/ on
#      the target, so a restore needs only the target's storage and the age identity.
#
# Usage: FROM=local TO=local-b scripts/portability/export.sh   (RUN_ID to name the run)
set -euo pipefail
# shellcheck source=scripts/portability/common.sh
source "$(dirname "$0")/common.sh"
require age git

use_run new
rm -f "$RUN_DIR/manifest/recovery-point.jsonl"
mkdir -p "$RUN_DIR/manifest"
backup_name="portability-$(tr '[:upper:]' '[:lower:]' <<<"$RUN_ID")"

preflight() {
  kc_env "$FROM" get nodes >/dev/null || die "cluster of $FROM is not reachable"
  note from "$FROM"
  note to "$TO"
  note run_id "$RUN_ID"
  note relay_infra_commit_export "$(git -C "$REPO_ROOT" rev-parse HEAD)"
  note relay_infra_dirty_export "$(git -C "$REPO_ROOT" status --porcelain | wc -l | tr -d ' ') changed paths"
  note source_s3 "$(env_var "$FROM" S3_MODE) $(env_var "$FROM" S3_CLUSTER_ENDPOINT)"
  note target_s3 "$(env_var "$TO" S3_MODE) $(env_var "$TO" S3_CLUSTER_ENDPOINT)"
  local nc
  for nc in "${PG_CLUSTERS[@]}"; do
    kc_env "$FROM" -n "${nc%%/*}" wait --for=condition=Ready "cluster/${nc#*/}" --timeout=60s >/dev/null
  done
  mkdir -p "$PORTABILITY_HOME"
  if [ ! -s "$AGE_KEY" ]; then
    age_keygen -o "$AGE_KEY" 2>/dev/null
    chmod 600 "$AGE_KEY"
    log "generated the age identity $AGE_KEY (keep it apart from the target's storage)"
  fi
}

backup() { # backup <namespace/cluster>
  local nc=$1 ns=${1%%/*} cluster=${1#*/} status
  kc_env "$FROM" apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: {name: $backup_name, namespace: $ns, labels: {relay.dev/portability-run: "$RUN_ID"}}
spec:
  cluster: {name: $cluster}
  method: plugin
  pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}
YAML
  kc_env "$FROM" -n "$ns" wait --for=jsonpath='{.status.phase}'=completed "backup/$backup_name" --timeout=600s >/dev/null ||
    die "backup $nc: $(kc_env "$FROM" -n "$ns" get backup "$backup_name" -o jsonpath='{.status.phase} {.status.error}')"
  status=$(kc_env "$FROM" -n "$ns" get backup "$backup_name" -o json | jq -c --arg nc "$nc" '{cluster: $nc,
    server_name: (.status.serverName // (.spec.cluster.name)), backup_id: .status.backupId,
    begin_lsn: .status.beginLSN, end_lsn: .status.endLSN, begin_wal: .status.beginWal, end_wal: .status.endWal,
    started_at: .status.startedAt, stopped_at: .status.stoppedAt}')
  jq -e '.backup_id and .end_wal' <<<"$status" >/dev/null || die "backup $nc has no backupId/endWal: $status"
  printf '%s\n' "$status" >>"$RUN_DIR/manifest/recovery-point.jsonl"
  log "recovery point for $nc: backup $(jq -r .backup_id <<<"$status"), end LSN $(jq -r .end_lsn <<<"$status")"
}

mark_after_backup() {
  psql_env "$FROM" relay-db/relay relay <<<"INSERT INTO portability.markers (run_id, event) VALUES ('$RUN_ID', 'after-backup') ON CONFLICT DO NOTHING"
  local nc
  for nc in "${PG_CLUSTERS[@]}"; do
    psql_env "$FROM" "$nc" postgres -At <<<"SELECT pg_switch_wal()" >/dev/null
  done
  note episodes_digest "$(psql_env "$FROM" relay-db/relay relay -At <<<"$EPISODES_DIGEST_SQL")"
}

inventory() {
  local script="" entry bucket prefix
  # shellcheck disable=SC2031 # bucket is local to this function
  for entry in "${COPY_BUCKETS[@]}"; do
    bucket=${entry%%:*} prefix=${entry#"$bucket"}
    prefix=${prefix#:}
    script+="rclone hashsum sha256 --download 'src:$bucket/$prefix' | sed 's|^\([0-9a-f]*\)  |@@ $bucket \1 $prefix|'
"
  done
  rclone_job "$FROM" inventory src="$FROM" -- "$script"
  cp "$RUN_DIR/jobs/inventory.out" "$RUN_DIR/inventory.txt"
  for entry in "${COPY_BUCKETS[@]}"; do
    bucket=${entry%%:*}
    awk -v b="$bucket" '$1 == b {print $2 "  " $3}' "$RUN_DIR/inventory.txt" | sort -k2 >"$RUN_DIR/manifest/$bucket.sha256"
    [ -s "$RUN_DIR/manifest/$bucket.sha256" ] || warn "$bucket: nothing to copy"
  done
  # Every object the recovery point needs must be in what we copy.
  local rp dest
  while read -r rp; do
    local server id end_wal
    server=$(jq -r .server_name <<<"$rp") id=$(jq -r .backup_id <<<"$rp") end_wal=$(jq -r .end_wal <<<"$rp")
    dest=cnpg/$server
    grep -q "  $dest/base/$id/backup.info$" "$RUN_DIR/manifest/relay-backups.sha256" ||
      die "$server: base backup $id is not in the inventory"
    grep -q "  $dest/wals/${end_wal:0:16}/$end_wal" "$RUN_DIR/manifest/relay-backups.sha256" ||
      die "$server: end-of-backup WAL $end_wal is not archived yet"
  done <"$RUN_DIR/manifest/recovery-point.jsonl"
}

copy_bucket() { # copy_bucket <bucket>
  local bucket=$1 list
  list=$(awk '{print $2}' "$RUN_DIR/manifest/$bucket.sha256")
  rclone_job "$FROM" "copy-$bucket" src="$FROM" dst="$TO" -- "
cat >/tmp/files <<'EOF'
$list
EOF
rclone copy --files-from-raw /tmp/files 'src:$bucket' 'dst:$bucket' --transfers 4 --use-json-log -v --stats 1h 2>/tmp/log || { tail -5 /tmp/log >&2; exit 1; }
grep '\"stats\"' /tmp/log | tail -1 | sed 's/^/@@ /'
"
  record_bytes "$(rclone_bytes <"$RUN_DIR/jobs/copy-$bucket.out")"
}

secrets_bundle() {
  local recipient bundle
  recipient=$(age_keygen -y "$AGE_KEY")
  # {"<source-secret name>": {key: value}}: what scripts/secrets.sh imports on the target.
  bundle=$(
    {
      kc_env "$FROM" -n relay-secret-source get secret keycloak-admin keycloak-test-users -o json |
        jq '.items[] | {(.metadata.name): (.data | map_values(@base64d))}'
      kc_env "$FROM" -n relay-db get secret relay-app -o json |
        jq '{"relay-db-app": (.data | {username, password} | map_values(@base64d))}'
      kc_env "$FROM" -n keycloak get secret keycloak-db-app -o json |
        jq '{"keycloak-db-app": (.data | {username, password} | map_values(@base64d))}'
    } | jq -s add
  )
  age -r "$recipient" -o "$RUN_DIR/secrets.age" <<<"$bundle"
  jq -r 'keys | join(", ")' <<<"$bundle" >"$RUN_DIR/manifest/secrets.txt"
  unset bundle
  note age_recipient "$recipient"
}

publish_manifest() {
  local entry bucket buckets="{}"
  for entry in "${COPY_BUCKETS[@]}"; do
    bucket=${entry%%:*}
    buckets=$(jq --arg b "$bucket" --arg p "${entry#"$bucket"}" --slurpfile d <(
      awk '{n++} END {print n + 0}' "$RUN_DIR/manifest/$bucket.sha256"
    ) --arg digest "$(shasum -a 256 "$RUN_DIR/manifest/$bucket.sha256" | cut -d' ' -f1)" \
      '. + {($b): {prefix: ($p | ltrimstr(":")), objects: $d[0], inventory: "\($b).sha256", inventory_sha256: $digest}}' <<<"$buckets")
  done
  jq -n --arg run "$RUN_ID" --arg from "$FROM" --arg to "$TO" \
    --arg commit "$(git -C "$REPO_ROOT" rev-parse HEAD)" \
    --arg digest "$(awk -F'\t' '$1 == "episodes_digest" {print $2}' "$RUN_DIR/facts.tsv")" \
    --slurpfile rp "$RUN_DIR/manifest/recovery-point.jsonl" --argjson buckets "$buckets" \
    --arg secrets "$(cat "$RUN_DIR/manifest/secrets.txt")" '{
      run_id: $run, from: $from, to: $to, relay_infra_commit: $commit, recovery_point: $rp,
      database: {table: "relay.portability.episodes", rows_and_md5: $digest,
                 marker_expected: "seeded", marker_absent: "after-backup"},
      buckets: $buckets, secrets: {file: "secrets.age", names: ($secrets | split(", "))}}' >"$RUN_DIR/manifest/manifest.json"
  cp "$RUN_DIR/secrets.age" "$RUN_DIR/manifest/secrets.age"
  s3_open dst "$TO"
  rclone copy "$RUN_DIR/manifest" "dst:$TARGET_RUN_PREFIX/$RUN_ID" \
    --exclude recovery-point.jsonl --exclude secrets.txt
  log "manifest: dst:$TARGET_RUN_PREFIX/$RUN_ID/manifest.json"
}

step export "preflight: $FROM reachable, age identity" preflight
for nc in "${PG_CLUSTERS[@]}"; do
  step export "CNPG backup $nc (recovery point)" backup "$nc"
done
step export "marker 'after-backup' and WAL switch" mark_after_backup
step export "inventory with SHA-256 (${COPY_BUCKETS[*]})" inventory
for entry in "${COPY_BUCKETS[@]}"; do
  step export "copy ${entry%%:*} $FROM → $TO" copy_bucket "${entry%%:*}"
done
step export "age-encrypted secrets bundle" secrets_bundle
step export "publish manifest to $TO" publish_manifest
log "export $RUN_ID done: $RUN_DIR"
