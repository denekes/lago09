#!/usr/bin/env bash
# fails-on-base.sh — show that your NEW/CHANGED tests fail against the code BEFORE your change.
#
# Usage (from anywhere in the lago repo; bash >= 4):
#   fails-on-base.sh [--base REV] [-- go test args]      # default go test args: -count=1 ./...
#   fails-on-base.sh -- -count=1 -run 'TestFoo' ./processors/events_processor/
#
# How: every events-processor production .go file (not *_test.go, not tests/) that differs
# between REV and the WORKING TREE is swapped back to its REV content through
# `go test -overlay`: modified -> REV content, added (or untracked) -> removed, deleted ->
# restored. Test files keep their current content. Nothing is written into the repo
# (change-control N10). Then the tests run: they are expected to FAIL.
# REV default: `git merge-base origin/main HEAD` if origin/main exists, else HEAD
# (= compare with the last commit, for uncommitted work).
# Read the result:
#   EVIDENCE OK      tests fail on REV (assertion failures)  -> paste this run + the green run
#   WEAK EVIDENCE    tests fail on REV only because they do not COMPILE there (new API):
#                    acceptable for a new function, type, struct field or option; paste the
#                    compile error it prints. For a change to existing API, prefer a test that
#                    compiles on REV and fails an assertion
#   NO EVIDENCE      tests PASS on REV: the test does not pin the change
# Exit: 0 EVIDENCE OK or WEAK EVIDENCE; 1 NO EVIDENCE; 2 setup error; 3 no production file
#   differs from REV (nothing to compare: a C1 test-only change, see validation-and-qa).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
base=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:?--base needs a revision}"; shift 2 ;;
    --) shift; args=("$@"); break ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "fails-on-base: unknown argument: $1 (go test args go after --)" >&2; exit 2 ;;
  esac
done
[ ${#args[@]} -gt 0 ] || args=(-count=1 ./...)
if [ -z "$base" ]; then
  if git -C "$repo" rev-parse -q --verify origin/main >/dev/null; then
    base="$(git -C "$repo" merge-base origin/main HEAD 2>/dev/null || git -C "$repo" rev-parse HEAD)"
  else
    base="$(git -C "$repo" rev-parse HEAD)"
  fi
fi
git -C "$repo" rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "fails-on-base: unknown revision $base" >&2; exit 2; }
echo "fails-on-base: base $(git -C "$repo" rev-parse --short=7 "$base")" >&2

tmp="$(mktemp -d "${TMPDIR:-/tmp}/vqa-fob.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
is_prod() { case "$1" in events-processor/tests/*|*_test.go) return 1 ;; events-processor/*.go) return 0 ;; *) return 1 ;; esac; }

entries=()
n=0
while IFS=$'\t' read -r st path; do
  is_prod "$path" || continue
  case "$st" in
    M|T|D) mkdir -p "$tmp/base/$(dirname "$path")"
           git -C "$repo" show "$base:$path" > "$tmp/base/$path"
           entries+=("\"$repo/$path\":\"$tmp/base/$path\"") ;;
    A)     entries+=("\"$repo/$path\":\"\"") ;;
    *)     echo "fails-on-base: unexpected status $st for $path" >&2; exit 2 ;;
  esac
  n=$((n + 1)); echo "  $st $path" >&2
done < <(git -C "$repo" diff --no-renames --name-status "$base" -- events-processor)
while IFS= read -r path; do
  is_prod "$path" || continue
  entries+=("\"$repo/$path\":\"\""); n=$((n + 1)); echo "  ? $path (untracked)" >&2
done < <(git -C "$repo" ls-files --others --exclude-standard -- events-processor)
if [ "$n" = 0 ]; then
  echo "fails-on-base: no production .go file differs from base: nothing to compare (test-only change)"; exit 3
fi
( IFS=,; printf '{"Replace":{%s}}\n' "${entries[*]}" ) > "$tmp/overlay.json"

# shellcheck source=/dev/null
source "$repo/.claude/skills/build-and-env/scripts/ep-env.sh" || { echo "fails-on-base: ep-env.sh failed" >&2; exit 2; }
cd "$repo/events-processor"
set +e
go test -overlay="$tmp/overlay.json" "${args[@]}" > "$tmp/out.txt" 2>&1
rc=$?
set -e
# Result lines, test failures and compile errors (file.go:line:col: ...) such as
# "undefined: X" or "unknown field Y in struct literal".
grep -E '^(ok|FAIL|---|\s+--- FAIL)|\[build failed\]|\[setup failed\]|cannot|undefined:|\.go:[0-9]+:[0-9]+: ' "$tmp/out.txt" | head -n 40 || true
if [ "$rc" = 0 ]; then
  echo "NO EVIDENCE: the selected tests PASS on base $(git -C "$repo" rev-parse --short=7 "$base") - they do not pin the change"; exit 1
fi
if grep -qE '\[build failed\]|\[setup failed\]' "$tmp/out.txt" && ! grep -qE -- '--- FAIL' "$tmp/out.txt"; then
  echo "WEAK EVIDENCE: the tests do not compile against base (new API: function, type, field or option); paste the compile error above, or prefer a test that compiles on base and fails an assertion"; exit 0
fi
echo "EVIDENCE OK: tests fail on base $(git -C "$repo" rev-parse --short=7 "$base") ($n production file(s) swapped back). Paste this output and the green run on your branch."
exit 0
