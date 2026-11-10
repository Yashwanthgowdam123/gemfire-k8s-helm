#!/usr/bin/env bash
# Checks generate-site-identity.sh for ecom/dev. Requires bash + yq (v4).
# Usage: tests/configuration/test-site-identity.sh <path-to-gemfire-application-config>
set -euo pipefail
cfgrepo=${1:?path to gemfire-application-config checkout}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
command -v yq >/dev/null || { echo "SKIP: yq not installed"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cfg=$cfgrepo/ecom/dev/values.yaml
for s in primary dr; do "$root/scripts/generate-site-identity.sh" "$cfg" $s "$tmp/$s.yaml" >/dev/null; done
eq() { [[ "$1" == "$2" ]] || { echo "FAIL: $3 (got '$1', want '$2')"; exit 1; }; }
eq "$(yq .site.distributedSystemId "$tmp/primary.yaml")" 21 "primary ds-id"
eq "$(yq .site.distributedSystemId "$tmp/dr.yaml")" 22 "dr ds-id"
eq "$(yq '.site.partner.locators | join(",")' "$tmp/primary.yaml")" "$(yq '.site.locators | join(",")' "$tmp/dr.yaml")" "primary's partner locators == DR locators"
eq "$(yq '.site.partner.locators | join(",")' "$tmp/dr.yaml")" "$(yq '.site.locators | join(",")' "$tmp/primary.yaml")" "DR's partner locators == Primary locators"
eq "$(yq 'keys | join(",")' "$tmp/dr.yaml")" site "identity has only the site key"
eq "$(yq '.site.tls.issuerName' "$tmp/dr.yaml")" gemfire-dev-ca "per-environment issuer"
if "$root/scripts/generate-site-identity.sh" "$cfg" secondary "$tmp/x.yaml" 2>/dev/null; then echo "FAIL: bad site accepted"; exit 1; fi
echo "PASS: site identity tests"
