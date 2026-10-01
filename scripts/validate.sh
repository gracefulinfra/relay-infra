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
    local ref=(--repo "$repo" "$chart") attempt
    [[ $repo == http* ]] || ref=("oci://$repo/$chart")
    # Chart hosts (GitHub release assets, registries) fail transiently; retry a few times, then fail.
    for attempt in 1 2 3; do
      helm pull "${ref[@]}" --version "$version" --destination "$dir" >/dev/null && break
      [ "$attempt" -lt 3 ] || die "helm pull $chart $version from $repo failed 3 times"
      warn "helm pull $chart $version failed (attempt $attempt); retrying"
      sleep $((attempt * 5))
    done
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
  if [ "$(env_var "$env" S3_MODE)" = external ]; then
    got=$(yq 'select(.kind == "Application" and .metadata.name == "relay-api") | .spec.source.helm.valuesObject.networkPolicy.s3[].to[].ipBlock.cidr' "$built")
    [ "$got" = "$(env_var "$env" EXTERNAL_S3_IP)/32" ] || die "envs/$env: relay-api S3 egress is '$got', env.sh EXTERNAL_S3_IP is $(env_var "$env" EXTERNAL_S3_IP)"
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

  # Every Application over a chart in this repository (apps/): render it from the working tree.
  local local_apps
  local_apps=$(yq 'select(.kind == "Application" and .spec.source.path != null and (.spec.source.path | test("^apps/")))
    | [.metadata.name, .spec.source.path, .spec.destination.namespace, (.spec.source.helm.releaseName // .metadata.name)] | join(" ")' "$built")
  while read -r name path namespace release; do
    [ -n "$name" ] || continue
    local values="$out/$env/helm/$name.values.yaml"
    yq ea "select(.kind == \"Application\" and .metadata.name == \"$name\") | .spec.source.helm.valuesObject // {}" \
      "$built" >"$values"
    helm template "$release" "$path" --namespace "$namespace" --values "$values" \
      --kube-version "$KUBERNETES_VERSION" >"$out/$env/helm/$name.yaml"
  done <<<"$local_apps"
}

# norm_image: drop the registry host and Docker Hub's library/ prefix, and map the one project that
# publishes under a different name per registry (Prometheus: prom/ on Docker Hub, prometheus/ on quay.io).
norm_image() { sed -E 's#^[a-z0-9.-]+\.[a-z]+(:[0-9]+)?/##; s#^library/##; s#^prom/#prometheus/#'; }

# check_compose_pins <rendered env dir>: every image the Compose dev stack runs (ADR 0009) must be the
# image the platform runs, at the same tag. PostgreSQL differs by design (the official image locally,
# the CNPG operand in the cluster), and so does Grafana's image variant, so only their versions are compared.
check_compose_pins() {
  local dir=$1 images img ref pg_dev pg_cnpg
  # Each platform image as repo:tag and, when pinned, repo@digest (some charts render only the digest).
  images=$(cat "$dir"/kustomize.yaml "$dir"/helm/*.yaml | grep -oE 'image: *"?[^" ]+' | sed -E 's/image: *"?//' |
    norm_image | awk '{print; if (sub(/@sha256:.*/, "")) print}' |
    awk '{print; if (match($0, /:[^:@\/]+@sha256:/)) print substr($0, 1, RSTART - 1) substr($0, index($0, "@"))}' | sort -u)
  for img in $(yq '.services[].image' compose/compose.yaml | sort -u); do
    ref=$(norm_image <<<"$img" | sed -E 's#@sha256:.*##')
    case $ref in
      postgres:*)
        pg_dev=$(sed -E 's/^postgres:([0-9.]+).*/\1/' <<<"$ref")
        pg_cnpg=$(yq 'select(.kind == "Cluster" and .metadata.name == "relay") | .spec.imageName' "$dir/kustomize.yaml" | sed -E 's/.*:([0-9.]+)-.*/\1/')
        [ "$pg_dev" = "$pg_cnpg" ] || die "compose PostgreSQL $pg_dev differs from the CNPG operand $pg_cnpg"
        ;;
      chrislusf/seaweedfs:*)
        [ "$img" = "$(sed -n 's/^SEAWEEDFS_IMAGE ?= //p' "$REPO_ROOT/Makefile")" ] ||
          die "compose SeaweedFS $img differs from the Makefile SEAWEEDFS_IMAGE"
        ;;
      grafana/grafana:*)
        # The platform chart runs the -distroless variant; the dev stack keeps the standard image for its
        # built-in HEALTHCHECK. Same Grafana version either way.
        grep -qE "^grafana/grafana:${ref#*:}(-distroless)?$" <<<"$images" ||
          die "compose Grafana $ref differs from the platform ($(grep -F grafana/grafana: <<<"$images" | tr '\n' ' '))"
        ;;
      *)
        grep -qxF "$ref" <<<"$images" || grep -qxF "${ref%%:*}@${img##*@}" <<<"$images" || die "compose image $ref is not what the platform runs (platform: $(grep -F "${ref%%:*}:" <<<"$images" | tr '\n' ' '))"
        ;;
    esac
  done
  log "compose dev stack images match the platform pins"
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
    [ "$env" != local ] || check_compose_pins "$out/$env"
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
