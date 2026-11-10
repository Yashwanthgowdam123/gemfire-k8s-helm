#!/usr/bin/env bash
# Usage: render-helm.sh <chart-dir> <config-values.yaml> <identity.yaml> <image-repo> <image-digest> <out-dir>
# Renders one site from: shared config + generated identity + digest-pinned image.
# Writes <out-dir>/rendered.yaml and <out-dir>/shared-config.sha256 (checksum of cache.xml,
# which must be identical for Primary and DR). Requires: bash, helm, yq; kubeconform optional.
set -euo pipefail
die() { echo "ERROR: $*" >&2; exit 1; }
[[ $# -eq 6 ]] || die "usage: $0 <chart-dir> <config> <identity> <image-repo> <image-digest> <out-dir>"
chart=$1; cfg=$2; ident=$3; repo=$4; digest=$5; out=$6
for t in helm yq; do command -v "$t" >/dev/null || die "$t not found in PATH"; done
[[ $digest =~ ^sha256:[a-f0-9]{64}$ ]] || die "image digest must be sha256:<64 hex>; tags are not allowed in the pipeline"
# The identity file may carry ONLY `site`; anything else could silently override shared settings.
[[ $(yq 'keys | join(",")' "$ident") == "site" ]] || die "identity file contains non-identity keys"

release=$(yq '.site.name' "$ident")
mkdir -p "$out"
args=(-f "$cfg" -f "$ident" --set image.repository="$repo" --set image.digest="$digest")
helm lint "$chart" "${args[@]}" --strict
helm template "$release" "$chart" --namespace "$release" "${args[@]}" > "$out/rendered.yaml"

cache_xml=$(yq 'select(.kind == "ConfigMap" and (.metadata.name | test("-config$"))) | .data."cache.xml"' "$out/rendered.yaml")
[[ -n $cache_xml && $cache_xml != null ]] || die "cache.xml not found in rendered ConfigMap"
printf '%s' "$cache_xml" | sha256sum | cut -d' ' -f1 > "$out/shared-config.sha256"

if command -v kubeconform >/dev/null; then kubeconform -strict -ignore-missing-schemas -summary "$out/rendered.yaml"
else echo "WARN: kubeconform not installed; manifest schema validation skipped" >&2; fi
echo "rendered $release -> $out/rendered.yaml (shared-config sha256 $(cut -c1-12 "$out/shared-config.sha256")...)"
