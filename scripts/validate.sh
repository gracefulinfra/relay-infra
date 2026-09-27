#!/usr/bin/env bash
# Offline-reproducible validation of everything Argo CD would apply.
#   scripts/validate.sh lint     helm lint --strict on app charts (apps/*)
#   scripts/validate.sh render   for every envs/<env>:
#                                  1. kustomize build the overlay
#                                  2. helm template every Helm Application in it with its valuesObject
#                                  3. kubeconform -strict everything, with CRD schemas generated from the
#                                     CRDs those same charts install (no third-party schema catalog)
# Usage: scripts/validate.sh lint|render [env...]
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require helm kubectl

KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.36.4}
CHART_CACHE=${CHART_CACHE:-$REPO_ROOT/.local/charts}
cd "$REPO_ROOT"

lint() {
  local charts=(apps/*/Chart.yaml)
  if [ ! -e "${charts[0]}" ]; then
    echo "SKIPPED: helm lint: apps/ has no charts yet (Relay app charts arrive in P1-01)."
    return 0
  fi
  for chart in "${charts[@]}"; do helm lint --strict "$(dirname "$chart")"; done
}

# pull_chart <repoURL> <chart> <version>: caches the chart tarball and prints its path.
pull_chart() {
  local repo=$1 chart=$2 version=$3
  local dir="$CHART_CACHE/${repo//[:\/]/_}"
  local tgz="$dir/$chart-$version.tgz"
  if [ ! -s "$tgz" ]; then
    mkdir -p "$dir"
    if [[ $repo == http* ]]; then
      helm pull "$chart" --repo "$repo" --version "$version" --destination "$dir" >/dev/null
    else
      helm pull "oci://$repo/$chart" --version "$version" --destination "$dir" >/dev/null
    fi
  fi
  printf '%s' "$tgz"
}

# crd_schemas <manifests> <outdir>: writes one JSON schema per CRD version in kubeconform's layout.
crd_schemas() {
  local manifests=$1 out=$2 line path
  yq -o json -I0 'select(.kind == "CustomResourceDefinition") | .spec as $s | $s.versions[]
    | select(.schema.openAPIV3Schema != null)
    | {"path": ($s.group + "/" + ($s.names.kind | downcase) + "_" + .name + ".json"), "schema": .schema.openAPIV3Schema}' \
    "$manifests" | while read -r line; do
    [ -n "$line" ] || continue
    path="$out/$(jq -r .path <<<"$line")"
    mkdir -p "$(dirname "$path")"
    jq '.schema' <<<"$line" >"$path"
  done
}

# check_env_settings <env> <rendered overlay>: values that env.sh repeats from the overlay (and from the
# env's k3d config) must agree, since scripts use one and pods the other.
check_env_settings() {
  local env=$1 built=$2 domain endpoint k3d want got
  domain=$(env_var "$env" DOMAIN)
  endpoint=$(env_var "$env" S3_CLUSTER_ENDPOINT)
  got=$(yq -N 'select(.kind == "Gateway" and .metadata.name == "relay") | .spec.listeners[].hostname' "$built" | sort -u)
  [ "$got" = "*.$domain" ] || die "envs/$env: env.sh DOMAIN=$domain, but the Gateway listens on '$got'"
  got=$(yq -N 'select(.kind == "ObjectStore") | .spec.configuration.endpointURL' "$built" | sort -u)
  [ "$got" = "$endpoint" ] || die "envs/$env: env.sh S3_CLUSTER_ENDPOINT=$endpoint, but ObjectStores use '$got'"
  k3d=$(env_var "$env" K3D_CONFIG)
  if [ "$(env_var "$env" S3_MODE)" = external ]; then
    want="$(env_var "$env" EXTERNAL_S3_IP) $(sed -E 's|^https?://([^:/]+).*|\1|' <<<"$endpoint")"
    got=$(yq '.hostAliases[] | .ip + " " + (.hostnames | join(" "))' "$k3d")
    [ "$got" = "$want" ] || die "envs/$env: $k3d hostAliases are '$got', env.sh says '$want'"
    [ "$(yq .network "$k3d")" = "$(env_var "$env" EXTERNAL_S3_NETWORK)" ] ||
      die "envs/$env: $k3d network differs from env.sh EXTERNAL_S3_NETWORK"
  fi
  [ "$(yq .metadata.name "$k3d")" = "$(env_var "$env" CLUSTER_NAME)" ] || die "envs/$env: $k3d name differs from env.sh CLUSTER_NAME"
  [ "$(yq .registries.create.name "$k3d")" = "$(env_var "$env" REGISTRY_NAME)" ] || die "envs/$env: $k3d registry differs from env.sh REGISTRY_NAME"
  log "envs/$env: env.sh agrees with the overlay and $k3d"
}

render_env() {
  local env=$1 out=$2
  local built="$out/$env/kustomize.yaml"
  mkdir -p "$out/$env/helm"
  kubectl kustomize "envs/$env" >"$built"

  # ADR-0007: secret values never live in git. Secrets reach workloads through ExternalSecrets only.
  local leaked
  leaked=$(yq 'select(.kind == "Secret" and (.data != null or .stringData != null)) | .metadata.namespace + "/" + .metadata.name' "$built")
  if [ -n "${leaked//$'\n'/}" ]; then
    die "envs/$env renders Secrets with data (use an ExternalSecret): $leaked"
  fi

  # The scripts' view of the env (envs/<env>/env.sh) must match what the overlay deploys.
  if [ -f "envs/$env/env.sh" ]; then
    check_env_settings "$env" "$built"
  fi

  # Every Application with a Helm chart source: render it the way Argo CD would.
  local apps
  apps=$(yq 'select(.kind == "Application" and .spec.source.chart != null)
    | [.metadata.name, .spec.source.repoURL, .spec.source.chart, .spec.source.targetRevision,
       .spec.destination.namespace, (.spec.source.helm.releaseName // .metadata.name)] | join(" ")' "$built")
  while read -r name repo chart version namespace release; do
    [ -n "$name" ] || continue
    local tgz values="$out/$env/helm/$name.values.yaml"
    tgz=$(pull_chart "$repo" "$chart" "$version")
    yq ea "select(.kind == \"Application\" and .metadata.name == \"$name\") | .spec.source.helm.valuesObject // {}" \
      "$built" >"$values"
    helm template "$release" "$tgz" --namespace "$namespace" --values "$values" --include-crds \
      --kube-version "$KUBERNETES_VERSION" >"$out/$env/helm/$name.yaml"
  done <<<"$apps"
}

render() {
  local envs=("$@")
  if [ ${#envs[@]} -eq 0 ]; then
    for d in envs/*/kustomization.yaml; do envs+=("$(basename "$(dirname "$d")")"); done
  fi
  out=$(mktemp -d)
  trap 'rm -rf "$out"' EXIT
  for env in "${envs[@]}"; do
    log "rendering envs/$env"
    render_env "$env" "$out"
    mkdir -p "$out/$env/schemas"
    for f in "$out/$env"/helm/*.yaml; do
      [[ $f == *.values.yaml ]] || crd_schemas "$f" "$out/$env/schemas"
    done
    # CRD objects themselves are upstream-owned and validated by the API server; kubeconform has no schema for them.
    log "validating envs/$env with kubeconform (Kubernetes $KUBERNETES_VERSION; CRD objects skipped)"
    find "$out/$env" -name '*.yaml' ! -name '*.values.yaml' -print0 |
      xargs -0 "$(go_tool kubeconform "github.com/yannh/kubeconform/cmd/kubeconform@v$KUBECONFORM_VERSION")" \
        -strict -summary -kubernetes-version "$KUBERNETES_VERSION" \
        -skip CustomResourceDefinition \
        -schema-location default \
        -schema-location "$out/$env/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  done
}

case ${1:-} in
  lint) lint ;;
  render)
    shift
    render "$@"
    ;;
  *)
    echo "usage: $0 lint|render [env...]" >&2
    exit 2
    ;;
esac
