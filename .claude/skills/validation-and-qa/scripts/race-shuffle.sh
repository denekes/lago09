#!/usr/bin/env bash
# race-shuffle.sh — order and concurrency checks for the events-processor test suite.
#
# Usage (from anywhere in the lago repo; bash >= 4):
#   race-shuffle.sh                     # -race once + -shuffle=<seed> -count=10 over ./...
#   race-shuffle.sh --isolation         # also run EVERY leaf test/subtest alone (catches
#                                       # subtests that depend on an earlier sibling; -shuffle
#                                       # only reorders top-level tests, never subtests)
#   race-shuffle.sh --count 3 --seed 42 # fewer shuffle rounds / reproduce a seed
#   race-shuffle.sh --no-race | --no-shuffle
#   race-shuffle.sh -- ./processors/... # restrict packages (default ./...)
#
# Steps (cwd events-processor/, CGO env from build-and-env/scripts/ep-env.sh, Postgres for
# config/database):
#   race       go test -race -count=1 <pkgs>            -> FAIL lines, "WARNING: DATA RACE" count
#   shuffle    go test -shuffle=<seed> -count=<n> <pkgs> -> FAIL lines; the seed is printed so a
#              failure is reproducible with --seed
#   isolation  go test -c per package, then <pkg>.test -test.run '^Top$/^Sub$' for every leaf
#              test, one process each. Known order-dependent leaves (listed below, verified
#              2026-10-01) are reported as KNOWN and do not fail the run.
# Exit: 0 clean (known isolation failures allowed); 1 a race, a failing test, or a NEW
#   isolation failure; 2 setup error. Writes only to a mktemp dir.
set -euo pipefail

# Leaf tests that fail when run alone at 5308258 (they read state set by an earlier sibling
# subtest of TestEvaluateExpression, processors/events_processor/enrichment_service_test.go:252-296).
KNOWN_ISOLATION_FAILURES=(
  "processors/events_processor TestEvaluateExpression/With_an_expression_and_with_required_fields"
  "processors/events_processor TestEvaluateExpression/With_a_float_timestamp"
)

in_list() { # needle, list... (no pipes: safe under pipefail)
  local needle="$1" x; shift
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
count=10
seed="$(date +%s)"
do_race=1; do_shuffle=1; do_iso=0
pkgs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --count) count="${2:?}"; shift 2 ;;
    --seed) seed="${2:?}"; shift 2 ;;
    --isolation) do_iso=1; shift ;;
    --no-race) do_race=0; shift ;;
    --no-shuffle) do_shuffle=0; shift ;;
    --) shift; pkgs=("$@"); break ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "race-shuffle: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ ${#pkgs[@]} -gt 0 ] || pkgs=(./...)

# shellcheck source=/dev/null
source "$repo/.claude/skills/build-and-env/scripts/ep-env.sh" || { echo "race-shuffle: ep-env.sh failed" >&2; exit 2; }
cd "$repo/events-processor"
porcelain_before="$(git -C "$repo" status --porcelain --ignored -- events-processor)"
mod="$(go list -m)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/vqa-race.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bad=0

report_fails() { # $1 log
  grep -E '^(--- FAIL|FAIL|panic:)|^\s+--- FAIL' "$1" | sed 's/ (.*//' | sort -u | head -n 30 | sed 's/^/    /' || true
}

if [ "$do_race" = 1 ]; then
  start=$(date +%s); set +e
  go test -race -count=1 "${pkgs[@]}" > "$tmp/race.txt" 2>&1; rc=$?
  set -e
  races=$(grep -c 'WARNING: DATA RACE' "$tmp/race.txt" || true)
  okp=$(grep -c '^ok ' "$tmp/race.txt" || true)
  if [ "$rc" = 0 ] && [ "$races" = 0 ]; then
    echo "OK   race: $okp packages ok, 0 DATA RACE ($(( $(date +%s) - start ))s)"
  else
    echo "FAIL race: exit $rc, $races DATA RACE warning(s)"; report_fails "$tmp/race.txt"; bad=1
  fi
fi

if [ "$do_shuffle" = 1 ]; then
  start=$(date +%s); set +e
  go test -shuffle="$seed" -count="$count" "${pkgs[@]}" > "$tmp/shuffle.txt" 2>&1; rc=$?
  set -e
  okp=$(grep -c '^ok ' "$tmp/shuffle.txt" || true)
  if [ "$rc" = 0 ]; then
    echo "OK   shuffle: seed $seed x$count, $okp packages ok ($(( $(date +%s) - start ))s)"
  else
    echo "FAIL shuffle: seed $seed x$count (reproduce: race-shuffle.sh --no-race --seed $seed --count $count)"
    report_fails "$tmp/shuffle.txt"; bad=1
  fi
fi

if [ "$do_iso" = 1 ]; then
  start=$(date +%s)
  # Collect every test name that ran, per package.
  set +e
  go test -count=1 -json "${pkgs[@]}" > "$tmp/names.json" 2> "$tmp/names.err"
  set -e
  awk -v mod="$mod" '
    match($0, /"Action":"run","Package":"[^"]*","Test":"[^"]*"/) {
      s = substr($0, RSTART, RLENGTH)
      p = s; sub(/^"Action":"run","Package":"/, "", p); sub(/","Test":.*/, "", p); sub("^" mod "/?", "", p); if (p == "") p = "."
      t = s; sub(/.*"Test":"/, "", t); sub(/"$/, "", t)
      print p "\t" t
    }' "$tmp/names.json" | sort -u > "$tmp/all.tsv"
  # Leaves: names that are not the parent of another name in the same package.
  awk -F'\t' '{ name[NR] = $0; pk[NR] = $1; t[NR] = $2; parent[$1 "\t" $2] = 0 }
    END {
      for (i = 1; i <= NR; i++) { x = t[i]; while (sub(/\/[^\/]*$/, "", x)) { parent[pk[i] "\t" x] = 1 } }
      for (i = 1; i <= NR; i++) if (!parent[name[i]]) print name[i]
    }' "$tmp/all.tsv" | sort > "$tmp/leaves.tsv"
  total=$(wc -l < "$tmp/leaves.tsv"); fails=0; known=0; newf=0; seen_known=()
  mkdir -p "$tmp/bin"
  while IFS= read -r p; do
    go test -c -o "$tmp/bin/$(echo "$p" | tr '/.' '__').test" "./$p" > /dev/null 2> "$tmp/build.err" || {
      echo "FAIL isolation: cannot build test binary for $p"; sed -n '1,5p' "$tmp/build.err"; bad=1; }
  done < <(cut -f1 "$tmp/leaves.tsv" | sort -u)
  while IFS=$'\t' read -r p t; do
    bin="$tmp/bin/$(echo "$p" | tr '/.' '__').test"
    [ -x "$bin" ] || continue
    pat=""
    IFS='/' read -r -a parts <<< "$t"
    for part in "${parts[@]}"; do
      esc="$(printf '%s' "$part" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
      pat+="${pat:+/}^${esc}\$"
    done
    if ! (cd "$p" && "$bin" -test.run "$pat" -test.count=1 > "$tmp/one.txt" 2>&1); then
      fails=$((fails + 1))
      if in_list "$p $t" "${KNOWN_ISOLATION_FAILURES[@]}"; then
        known=$((known + 1)); seen_known+=("$p $t"); echo "KNOWN isolation: $p $t"
      else
        newf=$((newf + 1)); echo "FAIL isolation: $p $t  (run alone: go test -count=1 -run '$pat' ./$p/)"
        { grep -E '_test\.go:[0-9]+:|Error:|expected|actual|panic' "$tmp/one.txt" || true; } | head -n 4 | sed 's/^/    /' || true
      fi
    fi
  done < "$tmp/leaves.tsv"
  if [ "$newf" -gt 0 ]; then bad=1; st=FAIL; else st=OK; fi
  printf '%-4s isolation: %d leaf tests run alone, %d failed (%d known, %d new) (%ds)\n' \
    "$st" "$total" "$fails" "$known" "$newf" "$(( $(date +%s) - start ))"
  for k in "${KNOWN_ISOLATION_FAILURES[@]}"; do
    awk -F'\t' -v p="${k%% *}" '$1 == p { f = 1 } END { exit !f }' "$tmp/leaves.tsv" || continue   # package not in scope
    in_list "$k" "${seen_known[@]}" || echo "INFO known failure did not reproduce (fixed or renamed? update KNOWN_ISOLATION_FAILURES): $k"
  done
fi

if [ "$bad" = 0 ]; then echo "SUMMARY race-shuffle: OK"; else echo "SUMMARY race-shuffle: FAIL"; fi
porcelain="$(git -C "$repo" status --porcelain --ignored -- events-processor)"
[ "$porcelain" = "$porcelain_before" ] || echo "WARN events-processor/ changed during the run (status before: ${porcelain_before:-clean}; after: $porcelain)" >&2
exit "$bad"
