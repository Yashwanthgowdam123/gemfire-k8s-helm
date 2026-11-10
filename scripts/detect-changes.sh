#!/usr/bin/env bash
# Detects WHICH application/environment configs changed between two commits of
# gemfire-application-config. Needs only git + bash. New folders are detected by PATTERN,
# so adding <newapp>/<env>/values.yaml needs no change to this script, the registry or the pipeline.
#
# Usage: detect-changes.sh <base-sha> <head-sha> [--json]
# stdout (TSV): <action> <app> <env> <path> [<old-path>]
#   action = added | modified            -> deployable (DR first, then Primary after approval)
#            deleted                      -> NEVER deployed, no teardown; needs a manual decommission request
#            invalid                      -> misnamed file (e.g. values.yml); never deployed
# --json also prints a GitHub Actions matrix of the deployable entries as the last stdout line.
# A renamed file is treated as a NEW application/environment (fresh DR deployment) with a warning.
# Exit: 0 = nothing wrong, 3 = at least one deleted/invalid entry (everything is still printed).
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: $0 <base-sha> <head-sha> [--json]" >&2; exit 2; }
base=$1; head=$2; json=${3:-}
[[ $base =~ ^0+$ ]] && base=$(git hash-object -t tree /dev/null)   # first push: compare with empty tree

ok='^([a-z][a-z0-9]{1,15})/([a-z]+)/values\.yaml$'
typo='^([a-z][a-z0-9]{1,15})/([a-z]+)/values\.(yml|YAML|yaml\.[a-z]+)$'
rc=0; items=()
emit() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}"; }
add_item() { items+=("{\"app\":\"$1\",\"env\":\"$2\",\"path\":\"$3\"}"); }

while IFS=$'\t' read -r status p1 p2; do
  case $status in
    A|M|T)
      if [[ $p1 =~ $ok ]]; then
        act=modified; [[ $status == A ]] && act=added
        emit "$act" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$p1"; add_item "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$p1"
      elif [[ $p1 =~ $typo ]]; then emit invalid "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$p1"; rc=3; fi ;;
    D)
      if [[ $p1 =~ $ok ]]; then emit deleted "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$p1"; rc=3; fi ;;
    R*|C*)
      if [[ $p2 =~ $ok ]]; then
        emit added "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$p2" "$p1"; add_item "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$p2"
        [[ $status == R* && $p1 =~ $ok ]] && echo "WARN: $p1 renamed to $p2; the old deployment is NOT removed (manual decommission)" >&2
      elif [[ $p2 =~ $typo ]]; then emit invalid "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$p2"; rc=3
      elif [[ $status == R* && $p1 =~ $ok ]]; then emit deleted "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$p1"; rc=3; fi ;;
  esac
done < <(git diff --name-status -M "$base" "$head")

if [[ $json == --json ]]; then
  ( IFS=,; printf '{"include":[%s]}\n' "${items[*]:-}" )
fi
exit $rc
