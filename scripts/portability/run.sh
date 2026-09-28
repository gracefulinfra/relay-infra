#!/usr/bin/env bash
# One portability rehearsal, end to end: target storage → source platform → seed → export → restore →
# verify → report. `make portability` runs it. See docs/portability.md.
#
#   FROM, TO     environments (default local → local-b)
#   RUN_ID       run name (default a UTC timestamp)
#   LOCAL_GIT=1  both clusters read the working tree from an in-cluster git server (scripts/up.sh)
#   CONFORMANCE=0  skip the S3 conformance suite against the target
set -euo pipefail
# shellcheck source=scripts/portability/common.sh
source "$(dirname "$0")/common.sh"
require k3d

use_run new
here=$(dirname "$0")
log "portability run $RUN_ID: $FROM → $TO (evidence in $RUN_DIR)"

target_storage() {
  if [ "$(env_var "$TO" S3_MODE)" = external ]; then
    RELAY_ENV=$TO "$REPO_ROOT/scripts/external-s3.sh" up
  fi
}
source_platform() {
  local c
  c=$(env_var "$FROM" CLUSTER_NAME)
  if ! k3d cluster list -o json | jq -e --arg c "$c" '.[] | select(.name == $c and .serversRunning > 0)' >/dev/null; then
    RELAY_ENV=$FROM "$REPO_ROOT/scripts/up.sh"
  fi
}

step setup "target storage for $TO" target_storage
step setup "source platform $FROM up" source_platform
"$here/seed.sh"
"$here/export.sh"
"$here/restore.sh"
"$here/verify.sh"
"$here/report.sh"
