#!/usr/bin/env bash
# smoke-binary.sh — build the events-processor binary into a temp dir and run it
# end to end against kfake (in-process Kafka on 127.0.0.1 TCP ports), miniredis
# and a throwaway Postgres DB; report where each of 9 test events (A..I) landed.
#
# Usage:
#   smoke-binary.sh [db|cache|cache-cdc|all] [--keep] [--no-expected] [--env K=V ...]
#     db         DB mode (default; the dev default)
#     cache      LAGO_USE_MEMORY_CACHE=true (snapshot from the scratch DB, no CDC traffic)
#     cache-cdc  cache + one hand-shaped Debezium `charges` row before start (production path,
#                DECIDED OD-1; the production column list is OPEN DECISION OD-1b)
#     all        the three modes in sequence
#     --keep         keep the temp dir (binary + logs) and print its path
#     --no-expected  do not compare with fixtures/smoke-expected-<mode>.txt
#     --env K=V      add (or override; K= sets it empty) one variable in the binary's
#                    otherwise fixed environment; repeatable. Use it to prove a new
#                    events-processor variable is wired end to end. A startup panic
#                    shows as `exit_before_sigterm=exit status 2` in the result block.
#
# Needs: go, cargo (first run, via ep-env.sh), psql + a reachable Postgres
# ($DATABASE_URL admin connection, see scratch-pg.sh). No Docker.
# Writes only to a mktemp dir and a scratch database (both removed on exit).
#
# Exit codes: 0 every mode ran and matched its expected-today file;
#             2 usage/setup/build error; 3 at least one mode differs from expected-today
#             (a measurement: read the diff, then update the expected file in the
#             same PR as the behaviour change).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"

modes=() keep=0 compare=1 extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    db|cache|cache-cdc) modes+=("$1") ;;
    all) modes+=(db cache cache-cdc) ;;
    --keep) keep=1 ;;
    --no-expected) compare=0 ;;
    --env)
      case "${2:-}" in
        [A-Za-z_]*=*) extra+=(-env "$2"); shift ;;
        *) echo "smoke-binary: --env needs K=V, got '${2:-}'" >&2; exit 2 ;;
      esac ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "smoke-binary: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ ${#modes[@]} -eq 0 ] && modes=(db)

cd "$repo"   # ep-env.sh finds the repo from the current directory
# shellcheck source=/dev/null
source "$repo/.claude/skills/build-and-env/scripts/ep-env.sh" || exit 2

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ep-smoke.XXXXXX")"
db="scratch_smoke_$$"
cleanup() {
  "$here/scratch-pg.sh" drop "$db" >/dev/null 2>&1 || true
  if [ "$keep" = 1 ]; then echo "smoke-binary: kept $tmp" >&2; else rm -rf "$tmp"; fi
}
trap cleanup EXIT

t0=$SECONDS
echo "smoke-binary: building events-processor -> $tmp/events-processor" >&2
(cd "$repo/events-processor" && go build -o "$tmp/events-processor" .) || exit 2
(cd "$here/kfake-harness" && go build -o "$tmp/smoke" ./cmd/smoke) || exit 2
echo "smoke-binary: build done in $((SECONDS - t0))s" >&2

url="$("$here/scratch-pg.sh" create "$db" "$here/fixtures/smoke-schema.sql")" || exit 2

rc=0
for m in "${modes[@]}"; do
  args=(-bin "$tmp/events-processor" -mode "$m" -db-url "$url" -log "$tmp/smoke-$m.log" ${extra[@]+"${extra[@]}"})
  exp="$here/fixtures/smoke-expected-$m.txt"
  if [ "$compare" = 1 ] && [ -f "$exp" ]; then args+=(-expected "$exp"); fi
  set +e
  "$tmp/smoke" "${args[@]}"
  r=$?
  set -e
  case "$r" in
    0) ;;
    3) rc=3 ;;
    *) echo "smoke-binary: mode $m setup error (exit $r)" >&2; exit 2 ;;
  esac
done
echo "smoke-binary: total $((SECONDS - t0))s, exit $rc" >&2
exit "$rc"
