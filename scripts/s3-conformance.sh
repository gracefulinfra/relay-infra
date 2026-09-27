#!/usr/bin/env bash
# Runs the S3 conformance suite (conformance/s3) against a local SeaweedFS.
#   scripts/s3-conformance.sh container [go test flags...]
#       Starts SeaweedFS ($SEAWEEDFS_IMAGE, the version platform/seaweedfs deploys) in Docker with fresh
#       random credentials, runs the suite, and removes the container. This is what CI runs.
#   scripts/s3-conformance.sh cluster [go test flags...]
#       Runs against the SeaweedFS in the k3d cluster (make up) through a port-forward, as the s3-admin
#       identity, in a scratch bucket that the suite creates and deletes.
#   RELAY_ENV=local-b scripts/s3-conformance.sh external [go test flags...]
#       Runs against the env's external S3 endpoint (S3_MODE=external, scripts/external-s3.sh) over TLS with
#       its CA, as its admin identity, in a scratch bucket that the suite creates and deletes.
# Extra flags go to `go test`, for example -target=seaweedfs-4.47 to write a report, or -run=TestS3Conformance/03.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require go docker jq

MODE=${1:-container}
shift || true
SEAWEEDFS_IMAGE=${SEAWEEDFS_IMAGE:?set SEAWEEDFS_IMAGE (the Makefile pins it)}
PORT=${S3_CONFORMANCE_PORT:-18333}
BUCKET=${S3_CONFORMANCE_BUCKET:-relay-conformance}
ACCESS_LOG_NOTE="SeaweedFS has no working S3 bucket-logging API. Its S3 gateway can send per-request audit records to Fluentd (weed -s3.auditLogConfig; not exercised by this suite). Relay would ship those, or the edge access logs, to relay-logs."

# The CI image must be the version the platform deploys: chart X.Y.0 ships image X.Y.
check_image_matches_chart() {
  local chart tag
  chart=$(sed -n 's/^ *targetRevision: \([0-9.]*\).*/\1/p' "$REPO_ROOT/platform/seaweedfs/application.yaml")
  tag=${SEAWEEDFS_IMAGE%%@*}
  tag=${tag##*:}
  [ "${chart%.0}" = "$tag" ] || die "SEAWEEDFS_IMAGE tag $tag does not match the SeaweedFS chart $chart in platform/seaweedfs; update them together"
}

wait_s3() {
  local url=$1 i code
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url/" || true)
    # 403 means the gateway is up and refusing anonymous requests.
    [ "$code" = 403 ] && return 0
    sleep 1
  done
  die "S3 at $url did not come up (last status $code after ${i}s)"
}

run_suite() {
  local endpoint=$1
  shift
  (cd "$REPO_ROOT" && go test -count=1 -timeout=20m -v ./conformance/s3 \
    -endpoint="$endpoint" -bucket="$BUCKET" -allow-bucket-config -access-log-note="$ACCESS_LOG_NOTE" "$@")
}


case $MODE in
container)
  check_image_matches_chart
  name=relay-s3-conformance-$$
  AWS_ACCESS_KEY_ID=relay-conformance-$(rand 8)
  AWS_SECRET_ACCESS_KEY=$(rand 40)
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
  log "starting $SEAWEEDFS_IMAGE on localhost:$PORT"
  # `weed mini` runs master, volume, filer, and the S3 gateway in one process, with S3 auth on for the
  # identity in AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY and S3_BUCKET created at startup.
  docker run -d --name "$name" -p "127.0.0.1:$PORT:8333" \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e S3_BUCKET="$BUCKET" "$SEAWEEDFS_IMAGE" >/dev/null
  wait_s3 "http://127.0.0.1:$PORT"
  run_suite "http://127.0.0.1:$PORT" "$@"
  ;;
cluster)
  require kubectl jq
  secret=$(kc -n relay-secret-source get secret s3-admin -o json) || die "no s3-admin secret: is the cluster up (make up)?"
  AWS_ACCESS_KEY_ID=$(jq -r '.data.access_key_id | @base64d' <<<"$secret")
  AWS_SECRET_ACCESS_KEY=$(jq -r '.data.secret_access_key | @base64d' <<<"$secret")
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  svc=$(kc -n seaweedfs get svc -o json | jq -r '[.items[] | select(any(.spec.ports[]; .port == 8333)) | .metadata.name][0] // empty')
  [ -n "$svc" ] || die "no Service exposing :8333 in namespace seaweedfs"
  log "port-forwarding svc/$svc:8333 to localhost:$PORT"
  kc -n seaweedfs port-forward "svc/$svc" "$PORT:8333" >/dev/null &
  pf=$!
  trap 'kill "$pf" 2>/dev/null || true' EXIT
  wait_s3 "http://127.0.0.1:$PORT"
  BUCKET=${S3_CONFORMANCE_BUCKET:-relay-conformance-$(date +%s)}
  run_suite "http://127.0.0.1:$PORT" -create-bucket "$@"
  ;;
external)
  [ "${S3_MODE:-}" = external ] || die "envs/$RELAY_ENV is not S3_MODE=external"
  creds="$S3_STATE_DIR/identities.json"
  [ -s "$creds" ] || die "no credentials in $creds: run RELAY_ENV=$RELAY_ENV scripts/external-s3.sh up"
  AWS_ACCESS_KEY_ID=$(jq -r .admin.access_key_id "$creds")
  AWS_SECRET_ACCESS_KEY=$(jq -r .admin.secret_access_key "$creds")
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  BUCKET=${S3_CONFORMANCE_BUCKET:-relay-conformance-$(date +%s)}
  run_suite "$S3_ENDPOINT" -create-bucket -ca-file="$S3_CA_FILE" "$@"
  ;;
*)
  die "usage: $0 container|cluster|external [go test flags...]"
  ;;
esac
