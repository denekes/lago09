#!/usr/bin/env bash
# scoreboard.sh — every event-accounting gate metric in one table, measured on the CURRENT
# checkout: fault-matrix ledger (accounting-probe) in DB mode AND in memory-cache mode
# (production runs memory-cache mode: DECIDED OD-1 (owner, 2026-10-02)), value corpus +
# ToTime precision (value-corpus), and unit-test coverage of ProcessEvents / processRecordsAndCommit.
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/event-accounting-campaign/scripts/scoreboard.sh [--no-accounting] [--no-coverage]
#                                                                 [--check-baseline] [--check-targets]
#   --no-accounting   skip the DB-mode kfake ledger (it needs Postgres at DATABASE_URL); the
#                     cache-mode ledger needs no Postgres and always runs
#   --no-coverage     skip the coverage run (config/database tests need Postgres too)
#   --check-baseline  exit 3 if any metric differs from the Phase-0 baseline recorded below
#                     (use it to prove a C1/C2 change did not move anything, or to see progress)
#   --check-targets   exit 4 if any metric misses its campaign target (the end-state CI gate)
#   A --check-* run is a gate only when every row was measured: rows skipped by
#   --no-accounting/--no-coverage print NOT MEASURED, count in "unmeasured=N" and make
#   the check exit 5 (incomplete), never 0. Gate line to paste: "moved=0 unmeasured=0".
#
# Writes only to a mktemp dir (removed on exit); builds via run.sh (temp -modfile) and
# `go test -coverprofile=<tmp>` on the packages that have tests (plain ./... coverage
# fails with `no such tool "covdata"` on packages without tests).
#
# Exit codes: 0 table printed (and every requested check passed on a full run);
#             2 a measurement failed to run (setup: Postgres, CGO env, build) or bad flag;
#             3 --check-baseline and a metric moved; 4 --check-targets and a target is
#             missed; 5 a --check-* flag was given but a row is NOT MEASURED (skipped).
#             Precedence: 2 > 3 > 4 > 5.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
do_acct=1; do_cov=1; chk_base=0; chk_tgt=0
for a in "$@"; do
  case "$a" in
    --no-accounting) do_acct=0 ;;
    --no-coverage) do_cov=0 ;;
    --check-baseline) chk_base=1 ;;
    --check-targets) chk_tgt=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "scoreboard: unknown flag $a" >&2; sed -n '2,28p' "$0" >&2; exit 2 ;;
  esac
done

# Phase-0 baseline, measured 2026-10-01 (cache_* rows added and measured 2026-10-02). Code facts
# as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only
# commits on top.
# metric|baseline|target|direction (eq: must equal target, le: <= target, gt: > target)
metrics=(
  "unaccounted_records|5|0|le"
  "lost|1|0|le"
  "skipped_retry|1|0|le"
  "sentry_only|3|0|le"
  "ledger_rows|36|36|eq"
  "cache_unaccounted_records|4|0|le"
  "cache_ledger_rows|26|26|eq"
  "corpus_value_mismatches|13|0|le"
  "corpus_go_decimal_mismatches|2|0|le"
  "corpus_end_to_end_decimal_mismatches|6|0|le"
  "totime_mismatches_per_1000|496|0|le"
  "rfc3339_normalised_utc_ms|false|true|eq"
  "cov_ProcessEvents_pct|0.0|0.0|gt"
  "cov_processRecordsAndCommit_pct|0.0|0.0|gt"
  "cov_total_tested_pkgs_pct|47.4|47.4|gt"
)

tmp="$(mktemp -d "${TMPDIR:-/tmp}/eac-score.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cd "$repo"
if [ -z "${LAGO_EXPRESSION_LIB:-}" ]; then
  # shellcheck source=/dev/null
  source .claude/skills/build-and-env/scripts/ep-env.sh >"$tmp/env.txt" 2>&1 || { cat "$tmp/env.txt" >&2; exit 2; }
fi

declare -A val
setup_err=0
kv() { # kv <line> <key> -> value of key=value in line
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
}

# memory-cache mode ledger (no Postgres needed; cases 1-3 have no cache-mode counterpart)
set +e; "$here/run.sh" accounting-probe -mode cache >"$tmp/acct-cache.txt" 2>"$tmp/acct-cache.err"; rc=$?; set -e
line="$(grep '^TOTALS ' "$tmp/acct-cache.txt" || true)"
if [ "$rc" -ge 100 ] || [ -z "$line" ]; then
  echo "scoreboard: accounting-probe -mode cache failed to run (rc=$rc):" >&2; tail -5 "$tmp/acct-cache.err" >&2; setup_err=1
else
  val[cache_unaccounted_records]="$(kv "$line" UNACCOUNTED)"; val[cache_ledger_rows]="$(kv "$line" rows)"
fi

if [ "$do_acct" = 1 ]; then
  set +e; "$here/run.sh" accounting-probe >"$tmp/acct.txt" 2>"$tmp/acct.err"; rc=$?; set -e
  line="$(grep '^TOTALS ' "$tmp/acct.txt" || true)"
  if [ "$rc" -ge 100 ] || [ -z "$line" ]; then
    echo "scoreboard: accounting-probe failed to run (rc=$rc):" >&2; tail -5 "$tmp/acct.err" >&2; setup_err=1
  else
    val[unaccounted_records]="$(kv "$line" UNACCOUNTED)"; val[lost]="$(kv "$line" LOST)"
    val[skipped_retry]="$(kv "$line" SKIPPED_RETRY)"; val[sentry_only]="$(kv "$line" SENTRY_ONLY)"
    val[ledger_rows]="$(kv "$line" rows)"
  fi
fi

set +e; "$here/run.sh" value-corpus >"$tmp/vc.txt" 2>"$tmp/vc.err"; rc=$?; set -e
line="$(grep '^SUMMARY ' "$tmp/vc.txt" || true)"
if [ "$rc" != 0 ] || [ -z "$line" ]; then
  echo "scoreboard: value-corpus failed to run (rc=$rc):" >&2; tail -5 "$tmp/vc.err" >&2; setup_err=1
else
  val[corpus_value_mismatches]="$(kv "$line" value_mismatches)"
  val[corpus_go_decimal_mismatches]="$(kv "$line" go_decimal_mismatches)"
  val[corpus_end_to_end_decimal_mismatches]="$(kv "$line" end_to_end_decimal_mismatches)"
  t="$(kv "$line" totime_mismatches)"; val[totime_mismatches_per_1000]="${t%/1000}"
  val[rfc3339_normalised_utc_ms]="$(kv "$line" rfc3339_utc_ms)"
fi

if [ "$do_cov" = 1 ]; then
  pkgs="$(cd events-processor && go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}{{end}}' ./... 2>/dev/null)"
  set +e
  (cd events-processor && go test -count=1 -coverprofile="$tmp/cover.out" $pkgs) >"$tmp/cov.txt" 2>&1; rc=$?
  set -e
  if [ "$rc" != 0 ]; then
    echo "scoreboard: coverage run failed (rc=$rc; Postgres down? see build-and-env):" >&2; tail -5 "$tmp/cov.txt" >&2; setup_err=1
  else
    (cd events-processor && go tool cover -func="$tmp/cover.out") >"$tmp/func.txt"
    val[cov_ProcessEvents_pct]="$(awk '$2=="ProcessEvents"{sub("%","",$3); print $3}' "$tmp/func.txt")"
    val[cov_processRecordsAndCommit_pct]="$(awk '$2=="processRecordsAndCommit"{sub("%","",$3); print $3}' "$tmp/func.txt")"
    val[cov_total_tested_pkgs_pct]="$(awk '$1=="total:"{sub("%","",$3); print $3}' "$tmp/func.txt")"
  fi
fi

meets() { # meets <value> <target> <dir>
  case "$3" in
    eq) [ "$1" = "$2" ] ;;
    le) awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 <= b+0)}' ;;
    gt) awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 > b+0)}' ;;
  esac
}

moved=0; missed=0; unmeasured=0
printf '%-40s %-10s %-10s %-10s %s\n' metric today baseline target status
printf '%-40s %-10s %-10s %-10s %s\n' ---------------------------------------- ---------- ---------- ---------- ------
for m in "${metrics[@]}"; do
  IFS='|' read -r name base target dir <<<"$m"
  now="${val[$name]:-}"
  if [ -z "$now" ]; then
    printf '%-40s %-10s %-10s %-10s %s\n' "$name" "-" "$base" "$dir $target" "NOT MEASURED"
    unmeasured=$((unmeasured+1))
    continue
  fi
  status="baseline"
  [ "$now" = "$base" ] || { status="CHANGED"; moved=$((moved+1)); }
  if meets "$now" "$target" "$dir"; then status="$status, TARGET MET"; else missed=$((missed+1)); fi
  printf '%-40s %-10s %-10s %-10s %s\n' "$name" "$now" "$base" "$dir $target" "$status"
done
echo "scoreboard: moved=$moved unmeasured=$unmeasured targets_missed=$missed (baseline 2026-10-01, cache_* 2026-10-02; targets are campaign TARGETS, not current state)"

[ "$setup_err" = 0 ] || exit 2
if [ "$chk_base" = 1 ] && [ "$moved" -gt 0 ]; then exit 3; fi
if [ "$chk_tgt" = 1 ] && [ "$missed" -gt 0 ]; then exit 4; fi
if [ $((chk_base + chk_tgt)) -gt 0 ] && [ "$unmeasured" -gt 0 ]; then
  echo "scoreboard: check incomplete: $unmeasured metric(s) NOT MEASURED (--no-accounting/--no-coverage); not a gate pass" >&2
  exit 5
fi
exit 0
