#!/usr/bin/env bash
# Verifies a restored target environment ($TO) against the run's manifest:
#   1. platform health: scripts/smoke.sh for $TO (GitOps, secrets, TLS, Gateway, S3 access rules, both
#      PostgreSQL clusters archiving to $TO's own backup path, Keycloak, Argo Workflows);
#   2. identity data: the staff and listener test users and the staff TOTP secret were restored with the
#      Keycloak database (smoke logs in with the carried credentials; nothing was re-imported);
#   3. database: row count and content digest of portability.episodes equal the source's, and the
#      markers prove recovery stopped at the recovery point ('seeded' present, 'after-backup' absent);
#   4. media: every object the restored database references is on $TO with the recorded SHA-256;
#   5. storage conformance: the P0-06 suite against $TO's S3, over HTTP/1.1 (must pass) and negotiated
#      HTTP/2 (recorded) (CONFORMANCE=0 skips it).
# Phase 0 has no application yet. From P1-20 this adds login, upload, process, publish, play and export.
#
# Usage: FROM=local TO=local-b scripts/portability/verify.sh   (RUN_ID, default the latest run)
set -euo pipefail
# shellcheck source=scripts/portability/common.sh
source "$(dirname "$0")/common.sh"

use_run
restore_dir=$RUN_DIR/restore
manifest=$restore_dir/manifest.json
[ -s "$manifest" ] || die "no restored manifest in $restore_dir: run restore.sh first"
CONFORMANCE=${CONFORMANCE:-1}

smoke() { RELAY_ENV=$TO "$REPO_ROOT/scripts/smoke.sh" 2>&1 | tee "$RUN_DIR/smoke-$TO.log" >&2; }

database() {
  local want got markers
  want=$(jq -r .database.rows_and_md5 "$manifest")
  got=$(psql_env "$TO" relay-db/relay relay -At <<<"$EPISODES_DIGEST_SQL")
  [ "$got" = "$want" ] || die "portability.episodes on $TO is '$got', the source had '$want'"
  markers=$(psql_env "$TO" relay-db/relay relay -At <<<"SELECT string_agg(event, ',' ORDER BY event)
    FROM portability.markers WHERE run_id = '$RUN_ID'")
  [ "$markers" = seeded ] || die "markers for $RUN_ID on $TO are '$markers'; expected only 'seeded' (recovery overshot or undershot)"
  note restored_episodes "$got (rows, md5) = source"
  note restored_markers "$markers ('after-backup' absent: recovery stopped at the backup)"
}

media_references() {
  local refs bad
  refs=$(psql_env "$TO" relay-db/relay relay -At -F ' ' <<<"SELECT DISTINCT media_sha256, media_key FROM portability.episodes ORDER BY 2")
  # media_key is <bucket>/<key>; the target inventory lists <sha256>  <key> per bucket.
  bad=$(while read -r sha key; do
    bucket=${key%%/*}
    grep -qx "$sha  ${key#*/}" "$restore_dir/target-$bucket.sha256" || echo "$key"
  done <<<"$refs")
  [ -z "$bad" ] || die "$(wc -l <<<"$bad" | tr -d ' ') referenced objects missing or different on $TO, e.g. $(head -1 <<<"$bad")"
  note referenced_objects "$(wc -l <<<"$refs" | tr -d ' ') distinct objects referenced by $(jq -r '.database.rows_and_md5 | split(" ")[0]' "$manifest") rows, all on $TO with matching SHA-256"
}

# The suite runs twice. HTTP/1.1 must pass: that is how Relay's S3 clients must talk to this target.
# The negotiated run (HTTP/2 over TLS, the AWS SDK default) is recorded, and its failures are reported
# as findings, because P0-06 ran only plain HTTP and cannot have seen them.
conformance() {
  local impl=${SEAWEEDFS_IMAGE:?}
  impl=${impl%%@*}
  impl="seaweedfs-${impl##*:}"
  RELAY_ENV=$TO SEAWEEDFS_IMAGE=$SEAWEEDFS_IMAGE "$REPO_ROOT/scripts/s3-conformance.sh" external \
    -target="$TO-$impl-https-http1" -http1 2>&1 | tee "$RUN_DIR/conformance-$TO-http1.log" >&2
  note conformance_http1 "passed (report conformance/s3/reports/$TO-$impl-https-http1-*.md)"
  if RELAY_ENV=$TO SEAWEEDFS_IMAGE=$SEAWEEDFS_IMAGE "$REPO_ROOT/scripts/s3-conformance.sh" external \
    -target="$TO-$impl-https-h2" >"$RUN_DIR/conformance-$TO-h2.log" 2>&1; then
    note conformance_h2 "passed"
  else
    note conformance_h2 "FAILED: $(grep -o 'HARD FAIL: .*' "$RUN_DIR/conformance-$TO-h2.log" | sed 's/HARD FAIL: //' | paste -sd ';' - | sed 's/;/; /g') (report conformance/s3/reports/$TO-$impl-https-h2-*.md)"
    warn "conformance over negotiated HTTP/2 failed; recorded as a finding (see the report)"
  fi
}

step verify "platform smoke on $TO" smoke
step verify "restored database: rows, digest, recovery point markers" database
step verify "every referenced media object on $TO (SHA-256)" media_references
if [ "$CONFORMANCE" = 1 ]; then step verify "S3 conformance suite against $TO's S3" conformance; fi
log "verify $RUN_ID passed"
