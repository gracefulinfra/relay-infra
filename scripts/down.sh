#!/usr/bin/env bash
# Deletes the k3d cluster and registry of $RELAY_ENV (default local). $RELAY_HOME (the local CA) is kept; delete it by hand to start over.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require k3d

if k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  k3d cluster delete "$CLUSTER_NAME"
else
  log "cluster $CLUSTER_NAME does not exist"
fi
if k3d registry get "$REGISTRY_NAME" >/dev/null 2>&1; then
  k3d registry delete "$REGISTRY_NAME"
fi
