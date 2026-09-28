# shellcheck shell=bash
# Script settings for envs/local-b, the second local "provider" of the P0-07 portability rehearsal
# (sourced by scripts/lib.sh). No secrets here. Values already set in the environment win.
: "${CLUSTER_NAME:=relay-b}"
: "${K3D_CONFIG:=envs/local-b/k3d.yaml}"
: "${REGISTRY_NAME:=relay-b-registry.localhost}"
: "${REGISTRY_HOST_PORT:=5002}"
: "${DOMAIN:=relay-b.localtest.me}"
# local-b has its own CA, so nothing issued for envs/local is trusted here.
: "${CA_DIR:=$RELAY_HOME/local-b/ca}"

# S3: an external SeaweedFS container that stands in for a provider's managed S3 (scripts/external-s3.sh).
# It is outside the cluster, speaks TLS with its own CA, and has its own credentials.
: "${S3_MODE:=external}"
# How host-side scripts reach it, and the CA that signs its certificate.
: "${S3_ENDPOINT:=https://localhost:18443}"
: "${S3_STATE_DIR:=$RELAY_HOME/local-b/s3}"
: "${S3_CA_FILE:=$S3_STATE_DIR/ca.crt}"
# How pods reach it. The overlay (ObjectStore endpointURL, Argo Workflows artifactRepository) and
# k3d.yaml (hostAliases) carry the same name, address and port; scripts/validate.sh checks they agree.
: "${S3_CLUSTER_ENDPOINT:=https://s3.relay-b.internal:8443}"
: "${EXTERNAL_S3_NAME:=relay-b-s3}"
: "${EXTERNAL_S3_NETWORK:=relay-b}"
: "${EXTERNAL_S3_SUBNET:=172.29.0.0/24}"
# Explicit, because the Linux Docker Engine records no gateway for a network created with only
# --subnet, and k3d then cannot create a cluster on it (Docker Desktop fills one in).
: "${EXTERNAL_S3_GATEWAY:=172.29.0.1}"
# Dynamic addresses (the k3d nodes) come from the upper half, so the fixed S3 address never collides.
: "${EXTERNAL_S3_IP_RANGE:=172.29.0.128/25}"
: "${EXTERNAL_S3_IP:=172.29.0.10}"
: "${EXTERNAL_S3_HOST_PORT:=18443}"
