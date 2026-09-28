#!/usr/bin/env bash
# The S3 endpoint outside the cluster, for environments with S3_MODE=external (envs/local-b). It stands
# in for a provider's managed S3: a SeaweedFS container on its own Docker network with a fixed address,
# served over TLS with its own CA, with per-consumer credentials. The k3d cluster joins the network
# and resolves the endpoint name through hostAliases (envs/<env>/k3d.yaml).
#
#   RELAY_ENV=local-b scripts/external-s3.sh up      create the CA, credentials, network and container; create the buckets
#   RELAY_ENV=local-b scripts/external-s3.sh down    remove the container, its data volume and the network (keeps the CA and credentials)
#   RELAY_ENV=local-b scripts/external-s3.sh purge   down, and delete the CA and credentials too
#   RELAY_ENV=local-b scripts/external-s3.sh attach <docker network>   make the endpoint reachable from
#       another cluster's network and print its address there (a managed S3 is reachable from anywhere;
#       this is the laptop's stand-in, used when another environment exports into this one)
#   RELAY_ENV=local-b scripts/external-s3.sh detach <docker network>
#
# State (CA, server certificate, credentials, IAM config) lives in $S3_STATE_DIR, outside git.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require docker openssl jq curl

[ "${S3_MODE:-}" = external ] || die "envs/$RELAY_ENV uses S3_MODE=${S3_MODE:-unset}; external-s3.sh is for S3_MODE=external"
: "${EXTERNAL_S3_NAME:?}" "${EXTERNAL_S3_NETWORK:?}" "${EXTERNAL_S3_SUBNET:?}" "${EXTERNAL_S3_GATEWAY:?}" "${EXTERNAL_S3_IP_RANGE:?}"
: "${EXTERNAL_S3_IP:?}" "${EXTERNAL_S3_HOST_PORT:?}" "${S3_CLUSTER_ENDPOINT:?}" "${S3_STATE_DIR:?}" "${S3_ENDPOINT:?}"
BUCKETS=(relay-media relay-feeds relay-backups relay-logs)
volume="$EXTERNAL_S3_NAME-data"
host=${S3_CLUSTER_ENDPOINT#https://}
port=${host##*:}
host=${host%%:*}

ensure_pki() {
  mkdir -p "$S3_STATE_DIR"
  chmod 700 "$RELAY_HOME" "$S3_STATE_DIR"
  local d=$S3_STATE_DIR
  if [ ! -s "$d/ca.key" ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 825 \
      -subj "/O=Relay $RELAY_ENV S3/CN=Relay $RELAY_ENV S3 CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -keyout "$d/ca.key" -out "$d/ca.crt" 2>/dev/null
    rm -f "$d/tls.crt"
    log "generated the $RELAY_ENV S3 CA in $d"
  fi
  if [ ! -s "$d/tls.crt" ]; then
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$host" \
      -keyout "$d/tls.key" -out "$d/tls.csr" 2>/dev/null
    openssl x509 -req -in "$d/tls.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial -days 397 \
      -extfile <(printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1,IP:%s\nextendedKeyUsage=serverAuth\n' "$host" "$EXTERNAL_S3_IP") \
      -out "$d/tls.crt" 2>/dev/null
    rm -f "$d/tls.csr"
  fi
  if [ ! -s "$d/identities.json" ]; then
    local entry name
    for entry in "${S3_IDENTITIES[@]}"; do
      name=${entry%%|*}
      jq -n --arg n "$name" --arg ak "$RELAY_ENV-$name-$(rand 12)" --arg sk "$(rand 40)" \
        '{($n): {access_key_id: $ak, secret_access_key: $sk}}'
    done | jq -s add >"$d/identities.json"
    log "generated S3 credentials in $d/identities.json"
  fi
  seaweedfs_iam_config <"$d/identities.json" >"$d/s3.json"
  chmod 600 "$d"/*.key "$d/identities.json" "$d/s3.json"
}

wait_tls() {
  local code i
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$S3_CA_FILE" "$S3_ENDPOINT/" || true)
    [ "$code" = 403 ] && return 0 # up, and refusing anonymous requests
    sleep 1
  done
  die "S3 at $S3_ENDPOINT did not come up over TLS (last status $code after ${i}s)"
}

up() {
  : "${SEAWEEDFS_IMAGE:?set SEAWEEDFS_IMAGE (the Makefile pins it)}"
  ensure_pki
  if ! docker network inspect "$EXTERNAL_S3_NETWORK" >/dev/null 2>&1; then
    docker network create --subnet "$EXTERNAL_S3_SUBNET" --gateway "$EXTERNAL_S3_GATEWAY" \
      --ip-range "$EXTERNAL_S3_IP_RANGE" "$EXTERNAL_S3_NETWORK" >/dev/null
    log "created Docker network $EXTERNAL_S3_NETWORK ($EXTERNAL_S3_SUBNET)"
  fi
  # Always (re)create the container: its credentials and certificate are fixed at creation, and may
  # have been regenerated since. The data is in the named volume, so it survives.
  docker rm -f "$EXTERNAL_S3_NAME" >/dev/null 2>&1 || true
  local envfile
  envfile=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$envfile'" RETURN
  seaweedfs_env_file "$envfile" "$S3_STATE_DIR/s3.json" "$S3_STATE_DIR/tls.crt" "$S3_STATE_DIR/tls.key"
  log "starting $SEAWEEDFS_IMAGE as $EXTERNAL_S3_NAME ($EXTERNAL_S3_IP:$port, host $S3_ENDPOINT)"
  docker run -d --name "$EXTERNAL_S3_NAME" --restart unless-stopped \
    --network "$EXTERNAL_S3_NETWORK" --ip "$EXTERNAL_S3_IP" \
    -p "127.0.0.1:$EXTERNAL_S3_HOST_PORT:$port" \
    -v "$volume:/data" --env-file "$envfile" \
    --entrypoint /bin/sh "$SEAWEEDFS_IMAGE" -c "$SEAWEEDFS_ENTRYPOINT" -- \
    mini -dir=/data -ip="$EXTERNAL_S3_IP" -master.telemetry=false -admin.ui=false \
    -s3.config=/run/relay-s3/s3.json -s3.port.https="$port" \
    -s3.cert.file=/run/relay-s3/tls.crt -s3.key.file=/run/relay-s3/tls.key >/dev/null
  wait_tls
  local b
  s3_open s3 "$RELAY_ENV"
  for b in "${BUCKETS[@]}"; do rclone mkdir "s3:$b"; done
  log "external S3 ready at $S3_ENDPOINT (in-cluster $S3_CLUSTER_ENDPOINT); buckets: ${BUCKETS[*]}"
}

down() {
  if docker rm -f "$EXTERNAL_S3_NAME" >/dev/null 2>&1; then log "removed container $EXTERNAL_S3_NAME"; fi
  if docker volume rm "$volume" >/dev/null 2>&1; then log "removed volume $volume"; fi
  if docker network inspect "$EXTERNAL_S3_NETWORK" >/dev/null 2>&1; then
    if docker network rm "$EXTERNAL_S3_NETWORK" >/dev/null 2>&1; then
      log "removed network $EXTERNAL_S3_NETWORK"
    else
      warn "network $EXTERNAL_S3_NETWORK is still in use (delete the $CLUSTER_NAME cluster first)"
    fi
  fi
}

attach() {
  local net=${1:?docker network}
  docker network inspect "$net" >/dev/null 2>&1 || die "no Docker network $net"
  if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$EXTERNAL_S3_NAME" | jq -e --arg n "$net" 'has($n)' >/dev/null; then
    docker network connect "$net" "$EXTERNAL_S3_NAME"
  fi
  docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$EXTERNAL_S3_NAME"
}

case ${1:-} in
  up) up ;;
  attach) attach "${2:-}" ;;
  detach) docker network disconnect "${2:?docker network}" "$EXTERNAL_S3_NAME" 2>/dev/null || true ;;
  down) down ;;
  purge)
    down
    rm -rf "$S3_STATE_DIR"
    log "deleted $S3_STATE_DIR"
    ;;
  *)
    echo "usage: RELAY_ENV=<env> $0 up|down|purge|attach <network>|detach <network>" >&2
    exit 2
    ;;
esac
