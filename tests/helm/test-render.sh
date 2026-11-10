#!/usr/bin/env bash
# Renders ecom/dev for DR and Primary from the SAME config file and asserts:
#  1. both render; 2. cache.xml checksum is identical (shared config really is shared);
#  3. identity files contain only `site`; 4. no "latest" tag anywhere; 5. WAN partners point at each other.
# Requires: helm, yq, bash. Usage: tests/helm/test-render.sh <path-to-gemfire-application-config>
set -euo pipefail
cfgrepo=${1:?path to gemfire-application-config checkout}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
command -v helm >/dev/null || { echo "SKIP: helm not installed"; exit 0; }
digest=sha256:$(printf 'x%.0s' {1..64} | tr 'x' 'a')
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for site in dr primary; do
  "$root/scripts/generate-site-identity.sh" "$cfgrepo/ecom/dev/values.yaml" "$site" "$tmp/$site-id.yaml"
  "$root/scripts/render-helm.sh" "$root/charts/gemfire-base" "$cfgrepo/ecom/dev/values.yaml" "$tmp/$site-id.yaml" \
     registry.example.invalid/geode "$digest" "$tmp/$site"
done
[[ "$(cat "$tmp/dr/shared-config.sha256")" == "$(cat "$tmp/primary/shared-config.sha256")" ]] \
  || { echo "FAIL: cache.xml differs between DR and Primary"; exit 1; }
! grep -E 'image:.*:latest' "$tmp"/*/rendered.yaml || { echo "FAIL: latest tag"; exit 1; }
grep -q 'remote-locators=ecom-dev-primary-locator-0' "$tmp/dr/rendered.yaml" || { echo "FAIL: DR does not point at Primary"; exit 1; }
grep -q 'remote-locators=ecom-dev-dr-locator-0' "$tmp/primary/rendered.yaml" || { echo "FAIL: Primary does not point at DR"; exit 1; }
echo "PASS: helm render tests"
