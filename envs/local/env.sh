# shellcheck shell=bash
# Script settings for envs/local (sourced by scripts/lib.sh). No secrets here: they live in the
# secret backend. Values already set in the environment win.
: "${CLUSTER_NAME:=relay}"
: "${K3D_CONFIG:=bootstrap/k3d.yaml}"
: "${REGISTRY_NAME:=relay-registry.localhost}"
: "${REGISTRY_HOST_PORT:=5001}"
# Base domain of the Gateway listener (the overlay patches the same value into the manifests).
: "${DOMAIN:=relay.localtest.me}"
# The CA behind ClusterIssuer relay-issuer; scripts/secrets.sh generates it once.
: "${CA_DIR:=$RELAY_HOME/ca}"
# S3: SeaweedFS runs in the cluster. Host-side tools reach it through a port-forward to this Service.
: "${S3_MODE:=in-cluster}"
: "${S3_NAMESPACE:=seaweedfs}"
: "${S3_SERVICE:=seaweedfs-all-in-one}"
: "${S3_SERVICE_PORT:=8333}"
# How pods reach it.
: "${S3_CLUSTER_ENDPOINT:=http://seaweedfs-all-in-one.seaweedfs.svc:8333}"
