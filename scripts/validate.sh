#!/usr/bin/env bash
# Lints every Helm chart, renders it, and validates the output with kubeconform.
# Usage: scripts/validate.sh lint|render
set -euo pipefail
cd "$(dirname "$0")/.."

KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.36.4}
KUBECONFORM=${KUBECONFORM:-go run github.com/yannh/kubeconform/cmd/kubeconform@v${KUBECONFORM_VERSION:?}}

charts=(charts/*/Chart.yaml)
if [ ! -e "${charts[0]}" ]; then
  echo "FAIL: no charts found under charts/" >&2
  exit 1
fi

case ${1:-} in
  lint)
    for chart in "${charts[@]}"; do helm lint --strict "$(dirname "$chart")"; done
    ;;
  render)
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT
    for chart in "${charts[@]}"; do
      dir=$(dirname "$chart")
      helm template "$(basename "$dir")" "$dir" > "$out/$(basename "$dir").yaml"
    done
    $KUBECONFORM -strict -summary -kubernetes-version "$KUBERNETES_VERSION" "$out"
    echo "PENDING: Kustomize overlays and CRD schemas are validated once P0-05 adds them."
    ;;
  *)
    echo "usage: $0 lint|render" >&2
    exit 2
    ;;
esac
