#!/usr/bin/env bash
# run-suite.sh - run the events-processor conformance catalogue (EPC-00..EPC-34) against an
# implementation under test (IUT). Black box: the IUT is any program configured through the
# environment-variable contract (reference/contract.md); the runner owns Kafka (in-process
# kfake over TCP), Redis (in-process miniredis over TCP) and a scratch Postgres database.
#
# Usage:
#   run-suite.sh --impl-cmd "CMD" [--impl-env K=V ...] [--mode db|cache]
#                [--profile compat|corrected|both] [--loose-errors] [--only REGEX]
#                [--keep DIR] [--pg-admin URL] [--runner-bin PATH]
#                [--golden-dir DIR] [--update]
#
#   --impl-cmd      command line of the IUT; started as `sh -c "exec CMD"` in its own process
#                   group (write a wrapper script when the IUT needs more than one command)
#   --impl-env      extra K=V for the IUT environment (repeatable), e.g. LD_LIBRARY_PATH=...
#   --mode          db (default): the IUT reads the catalog from Postgres per event
#                   cache: memory-cache mode (LAGO_USE_MEMORY_CACHE=true, six CDC topics seeded)
#   --profile       compat    = golden text of the reference behaviour (conformance/golden/compat-<mode>/)
#                   corrected = assertion files (conformance/golden/corrected/), rulings decided|proposed
#                   both      = both in the same run (default)
#   --loose-errors  compat comparison masks implementation text: initial_error_message and the
#                   exact non-zero exit status of a startup failure (portable compat for non-reference IUTs)
#   --only          regex on the scenario file name (e.g. 'EPC-0[0-9]')
#   --keep          directory for observed goldens and IUT logs
#                   (default $LAGO_SKILLS_CACHE/epconf-runs/<UTC time>-<mode>)
#   --pg-admin      admin Postgres URL used by the RUNNER to create the scratch database and the
#                   SELECT-only role epconf_iut (default $EPCONF_PG_ADMIN_URL, else
#                   postgres://lago:lago@localhost:5432/lago). Never the IUT's DATABASE_URL.
#   --runner-bin    use this prebuilt epconf binary instead of building scripts/runner
#   --golden-dir    read (or with --update write) compat goldens here instead of the shipped directory
#   --update        MAINTAINER: write the observed text as the compat golden (use
#                   maintainer/regen-goldens.sh, which writes to a temp dir and shows the diff)
#
# Requirements: Go >= 1.25 to build the runner once (module download through the Go proxy;
# binary cached in $LAGO_SKILLS_CACHE/epconf-bin/<source sha>/), `psql` on PATH, a Postgres >= 15
# role that can CREATE DATABASE and CREATE ROLE. Kafka and Redis are owned by the runner.
#
# Output: one line per scenario
#   "<scenario> compat=MATCH|DIFF|WRITTEN|NO_GOLDEN|- corrected=PASS|FAIL|UNRULED|- (Ns)"
#   corrected=UNRULED: only assertions whose ruling is "proposed" failed (advisory)
# then: "run-suite: scenarios=N failing=N unruled=N skipped=N mode=M profile=P exit=E"
# Exit: 0 every requested check passed (UNRULED does not fail); 3 at least one DIFF/FAIL/NO_GOLDEN;
#       2 setup error (usage, build, Postgres, runner setup).
# Writes: the runner binary and run output under $LAGO_SKILLS_CACHE (or --keep); a scratch
# database epconf_<pid> per scenario (dropped afterwards) and the cluster role epconf_iut.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
conf="$root/conformance"
cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"

impl=""; mode=db; profile=both; update=0; only='.'; keep=""; runner_bin=""; golden_dir=""
pg_admin="${EPCONF_PG_ADMIN_URL:-postgres://lago:lago@localhost:5432/lago}"
rargs=()
usage() { sed -n '2,49p' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --impl-cmd) impl="${2:?}"; shift ;;
    --impl-env) rargs+=(-impl-env "${2:?}"); shift ;;
    --mode) mode="${2:?}"; shift ;;
    --profile) profile="${2:?}"; shift ;;
    --loose-errors) rargs+=(-loose-errors) ;;
    --only) only="${2:?}"; shift ;;
    --keep) keep="${2:?}"; shift ;;
    --pg-admin) pg_admin="${2:?}"; shift ;;
    --runner-bin) runner_bin="${2:?}"; shift ;;
    --golden-dir) golden_dir="${2:?}"; shift ;;
    --update) update=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run-suite: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$impl" ] || { echo "run-suite: --impl-cmd is required" >&2; exit 2; }
case "$mode" in db|cache) ;; *) echo "run-suite: --mode must be db or cache" >&2; exit 2 ;; esac
case "$profile" in compat|corrected|both) ;; *) echo "run-suite: --profile must be compat, corrected or both" >&2; exit 2 ;; esac
command -v psql >/dev/null 2>&1 || { echo "run-suite: psql not found on PATH" >&2; exit 2; }
psql "$pg_admin" -XAtqc 'select 1' >/dev/null 2>&1 || { echo "run-suite: cannot connect to the admin Postgres URL (--pg-admin)" >&2; exit 2; }

# Build (or reuse) the runner binary, keyed by the sha256 of its sources.
if [ -z "$runner_bin" ]; then
  sha="$(cat "$here/runner/main.go" "$here/runner/go.mod" "$here/runner/go.sum" | sha256sum | cut -c1-16)"
  runner_bin="$cache/epconf-bin/$sha/epconf"
  if [ ! -x "$runner_bin" ]; then
    command -v go >/dev/null 2>&1 || { echo "run-suite: go not found (Go >= 1.25 builds the runner)" >&2; exit 2; }
    mkdir -p "$cache/epconf-bin/$sha"
    echo "run-suite: building the runner into $runner_bin" >&2
    (cd "$here/runner" && GOFLAGS=-mod=readonly go build -o "$runner_bin.tmp" . && mv "$runner_bin.tmp" "$runner_bin") \
      || { echo "run-suite: runner build failed" >&2; exit 2; }
  fi
fi
[ -x "$runner_bin" ] || { echo "run-suite: runner binary $runner_bin not executable" >&2; exit 2; }

[ -n "$keep" ] || keep="$cache/epconf-runs/$(date -u +%Y%m%dT%H%M%SZ)-$mode"
mkdir -p "$keep"
gd="${golden_dir:-$conf/golden/compat-$mode}"
[ "$update" = 1 ] && echo "run-suite: --update writes observed goldens into $gd (review the diff before shipping)" >&2
mkdir -p "$gd"

rc=0; n=0; bad=0; unruled=0; skipped=0
for sc in "$conf"/scenarios/EPC-*.json; do
  name="$(basename "$sc" .json)"
  [[ "$name" =~ $only ]] || continue
  desc="$("$runner_bin" -describe -scenario "$sc" -mode "$mode")" || { echo "$name setup error (scenario file)"; rc=2; continue; }
  if [[ "$desc" == *"applies=false"* ]]; then echo "$name SKIPPED (mode $mode)"; skipped=$((skipped+1)); continue; fi
  n=$((n+1))
  args=(-impl-cmd "$impl" -scenario "$sc" -keep "$keep" -mode "$mode" -pg-admin "$pg_admin" ${rargs[@]+"${rargs[@]}"})
  g="$gd/$name.golden"; a="$conf/golden/corrected/$name.assert.json"
  if [ "$profile" != corrected ] && [[ "$desc" == *"no_golden=false"* ]]; then
    if [ "$update" = 0 ] && [ ! -f "$g" ]; then echo "$name compat=NO_GOLDEN"; bad=$((bad+1)); [ "$rc" = 0 ] && rc=3; continue; fi
    args+=(-golden "$g"); [ "$update" = 1 ] && args+=(-update)
  fi
  if [ "$profile" != compat ] && [ -f "$a" ]; then args+=(-assert "$a"); fi
  t0=$(date +%s.%N)
  set +e
  out="$("$runner_bin" "${args[@]}" 2>"$keep/$name.stderr")"; r=$?
  set -e
  printf '%s\n' "$out" > "$keep/$name.out"
  dt=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')
  c=-; k=-
  grep -q '^== GOLDEN MATCH' <<<"$out" && c=MATCH
  grep -q '^== GOLDEN DIFFERS' <<<"$out" && c=DIFF
  grep -q '^== GOLDEN WRITTEN' <<<"$out" && c=WRITTEN
  grep -q '^== ASSERTIONS PASS' <<<"$out" && k=PASS
  grep -q '^== ASSERTIONS UNRULED' <<<"$out" && k=UNRULED
  grep -q '^== ASSERTIONS FAILED' <<<"$out" && k=FAIL
  echo "$name compat=$c corrected=$k (${dt}s)"
  if [ "$r" = 2 ]; then echo "  setup error: $(tail -1 "$keep/$name.stderr")"; rc=2; fi
  [ "$k" = UNRULED ] && unruled=$((unruled+1))
  if [ "$c" = DIFF ] || [ "$k" = FAIL ]; then bad=$((bad+1)); [ "$rc" = 0 ] && rc=3; fi
done
echo "run-suite: scenarios=$n failing=$bad unruled=$unruled skipped=$skipped mode=$mode profile=$profile keep=$keep exit=$rc"
exit "$rc"
