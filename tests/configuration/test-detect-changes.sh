#!/usr/bin/env bash
# Builds a throwaway git repo and checks scripts/detect-changes.sh behaviour. Needs only git + bash.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
detect=$root/scripts/detect-changes.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"; git init -q; git config user.email t@t; git config user.name t
pass=0; fail() { echo "FAIL: $*"; exit 1; }
ok() { pass=$((pass+1)); echo "ok - $*"; }
commit() { git add -A; git commit -qm "$1"; git rev-parse HEAD; }
put() { mkdir -p "$(dirname "$1")"; echo "$2" > "$1"; }

put ecom/dev/values.yaml "a: 1"; put README.md x; first=$(commit init)

# 1. modify ecom/dev only
put ecom/dev/values.yaml "a: 2"; c1=$(commit m)
out=$("$detect" "$first" "$c1" --json)
[[ $(grep -c . <<<"$out") -eq 2 ]] || fail "expected 1 entry + json, got: $out"
grep -qP '^modified\tecom\tdev\tecom/dev/values.yaml' <<<"$out" || fail "modified not reported"
grep -q '{"include":\[{"app":"ecom","env":"dev","path":"ecom/dev/values.yaml"}\]}' <<<"$out" || fail "matrix wrong: $out"
ok "ecom/dev change -> only ecom/dev"

# 2. NEW application folder is detected with no registry/pipeline change
put swp/dev/values.yaml "a: 1"; c2=$(commit new-app)
out=$("$detect" "$c1" "$c2")
grep -qP '^added\tswp\tdev\tswp/dev/values.yaml' <<<"$out" || fail "new folder not detected"
[[ $(grep -c . <<<"$out") -eq 1 ]] || fail "extra entries: $out"
ok "new swp/dev folder detected automatically"

# 3. unrelated files -> nothing, empty matrix
put docs/x.md hello; put schemas/s.json '{}'; c3=$(commit docs)
out=$("$detect" "$c2" "$c3" --json)
[[ $out == '{"include":[]}' ]] || fail "unrelated change produced: $out"
ok "unrelated change -> no deployments"

# 4. two files in one commit -> two independent entries
put ecom/dev/values.yaml "a: 3"; put b2c/prod/values.yaml "a: 1"; c4=$(commit two)
out=$("$detect" "$c3" "$c4" --json)
grep -q '"app":"ecom"' <<<"$out" && grep -q '"app":"b2c"' <<<"$out" || fail "two entries expected: $out"
[[ $(grep -o '"app"' <<<"$out" | wc -l) -eq 2 ]] || fail "matrix should have exactly 2 entries"
ok "multiple changed configs -> processed independently"

# 5. deletion: reported, exit 3, never in matrix
git rm -q swp/dev/values.yaml; c5=$(commit del)
set +e; out=$("$detect" "$c4" "$c5" --json); rc=$?; set -e
[[ $rc -eq 3 ]] || fail "delete should exit 3, got $rc"
grep -qP '^deleted\tswp\tdev' <<<"$out" || fail "delete not reported"
[[ $out == *'{"include":[]}'* ]] || fail "deleted config must not be deployable"
ok "deleted config -> reported, exit 3, not deployed"

# 6. rename: new path treated as new deployment, old path warned about
git mv b2c/prod/values.yaml b2c/prod2.tmp 2>/dev/null || true; mkdir -p b2c/qa; git mv b2c/prod2.tmp b2c/qa/values.yaml
c6=$(commit rename)
out=$("$detect" "$c5" "$c6" 2>"$tmp/err")
grep -qP '^added\tb2c\tqa\tb2c/qa/values.yaml\tb2c/prod/values.yaml' <<<"$out" || fail "rename not seen as added: $out"
grep -q 'NOT removed' "$tmp/err" || fail "rename warning missing"
ok "rename -> new deployment + decommission warning"

# 7. misnamed file
put ecom/dev/values.yml "a: 1"; c7=$(commit typo)
set +e; out=$("$detect" "$c6" "$c7"); rc=$?; set -e
[[ $rc -eq 3 ]] && grep -qP '^invalid\tecom\tdev' <<<"$out" || fail "values.yml should be invalid"
ok "misnamed values.yml -> invalid, exit 3"

# 8. first push (all-zero base)
out=$("$detect" 0000000000000000000000000000000000000000 "$first")
grep -qP '^added\tecom\tdev' <<<"$out" || fail "first push not handled"
ok "first push compared with empty tree"
echo "PASS: $pass checks"
