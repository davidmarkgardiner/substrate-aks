#!/usr/bin/env bash
# Run on a host WITH Internet access (stands in for your air-gap process).
# Mirrors everything install-kagent.sh needs into an internal registry and an
# assets directory, so the install itself needs no public dependency.
#   seed-kagent-airgap.sh <registry-name> <assets-dir>
set -euo pipefail
ACR="$1"; OUT="$2"; V="${KAGENT_VERSION:-1.0.1}"
mkdir -p "$OUT"
helm pull "oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds" --version "$V" -d "$OUT"
helm pull "oci://ghcr.io/kagent-dev/kagent/helm/kagent" --version "$V" -d "$OUT"
curl -fsSL "https://raw.githubusercontent.com/kagent-dev/kagent/v$V/go/core/pkg/postgressetup/setup.sql" -o "$OUT/kagent-setup.sql"
# Every image the chart (and its subcharts and built-in harnesses) can start.
helm template kagent "$OUT/kagent-$V.tgz" -n kagent --set providers.openAI.apiKey=x \
  --set substrateWorkerPool.create=true --set harnesses.enabled=true --set substrateWorkerPool.workerImage=x \
  | grep -oE '(ghcr\.io|docker\.io|cr\.kagent\.dev)/[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?(@sha256:[a-f0-9]{64})?' | sort -u > "$OUT/images.txt"
echo "library/postgres:17-alpine" >> "$OUT/images.txt.extra"
while read -r img; do
  repo="${img#*/}"; repo="${repo%%[:@]*}"
  tag=$(printf '%s' "$img" | grep -oE ':[A-Za-z0-9._-]+($|@)' | head -1 | tr -d ':@' || true)
  if [[ "$img" == *@sha256:* ]]; then
    echo "import $img -> $ACR/$repo (by digest)"
    az acr import -n "$ACR" --source "$img" --image "$repo:${tag:-pinned}" --force -o none
  else
    echo "import $img -> $ACR/$repo:${tag:-latest}"
    az acr import -n "$ACR" --source "$img" --image "$repo:${tag:-latest}" --force -o none
  fi
done < "$OUT/images.txt"
az acr import -n "$ACR" --source docker.io/library/postgres:17-alpine --image library/postgres:17-alpine --force -o none
echo "seeded: $(wc -l < "$OUT/images.txt") chart images + postgres; assets in $OUT"
