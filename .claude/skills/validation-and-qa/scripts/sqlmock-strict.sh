#!/usr/bin/env bash
# sqlmock-strict.sh — run the suite as if tests.SetupMockStore enforced sqlmock ExpectationsWereMet().
#
# Usage (from anywhere in the lago repo; bash >= 4):
#   sqlmock-strict.sh            # report unmet expectations; exit 1 only on NEW ones
#   sqlmock-strict.sh --all      # exit 1 on ANY unmet expectation (the target state)
#   sqlmock-strict.sh --keep     # keep the temp dir (strict mocked_store.go + overlay.json)
#   sqlmock-strict.sh -- ./models/   # restrict packages (default ./...)
#
# Why: events-processor/tests/mocked_store.go returns a cleanup that only closes the mock DB.
# Nothing in the suite calls ExpectationsWereMet() (grep finds 0 calls), so a test that
# registers a query the code never runs still passes. This script derives a strict copy of
# that file (the cleanup first calls mock.ExpectationsWereMet() and t.Errorf's on error),
# overlays it with `go test -overlay` (the repo is never written, change-control N10) and
# runs the tests. Every SetupMockStore user is covered (models via setupApiStore, and the
# DB-mode DataStore of processors/events_processor).
#
# Known unmet expectations at 5308258 (verified 2026-10-01), all in DB mode:
#   - timestamp-invalid cases register a billable_metrics query, but ToEnrichedEvent fails first;
#   - the api_post_processed case registers a charges query that is skipped for such events;
#   - the expression-failure case registers a subscriptions query that is never reached.
# Exit: 0 no unmet expectation outside the known list (or none at all with --all);
#       1 a NEW unmet expectation or another test failure; 2 setup error (file shape changed).
set -euo pipefail

KNOWN_UNMET=(
  "processors/events_processor TestEnrichEvent/WithoutCache/When_timestamp_is_invalid"
  "processors/events_processor TestProcessEvent/When_event_source_is_post_processed_on_API#01"
  "processors/events_processor TestProcessEvent/When_event_source_is_not_post_process_on_API_when_timestamp_is_invalid#01"
  "processors/events_processor TestProcessEvent/When_event_source_is_not_post_process_on_API_when_expression_failed_to_evaluate#01"
)

in_list() { # needle, list... (no pipes: safe under pipefail)
  local needle="$1" x; shift
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
ep="$repo/events-processor"
src="$ep/tests/mocked_store.go"
all=0; keep=0; pkgs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) all=1; shift ;;
    --keep) keep=1; shift ;;
    --) shift; pkgs=("$@"); break ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "sqlmock-strict: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ ${#pkgs[@]} -gt 0 ] || pkgs=(./...)
[ -f "$src" ] || { echo "sqlmock-strict: $src not found" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/vqa-sqlmock.XXXXXX")"
if [ "$keep" = 0 ]; then trap 'rm -rf "$tmp"' EXIT; else echo "sqlmock-strict: keeping $tmp" >&2; fi

if grep -q 'ExpectationsWereMet' "$src"; then
  echo "INFO tests/mocked_store.go already calls ExpectationsWereMet(): running the suite unmodified"
  cp "$src" "$tmp/mocked_store.go"
else
  # Insert the check right before mockDB.Close() inside the returned cleanup closure.
  awk '
    /return mockedStore, func\(\) \{/ { inclosure = 1 }
    inclosure && /^[[:space:]]*mockDB\.Close\(\)[[:space:]]*$/ && !done {
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
      print ind "if err := mock.ExpectationsWereMet(); err != nil {"
      print ind "\tt.Errorf(\"SQLMOCK-STRICT unmet expectations: %v\", err)"
      print ind "}"
      done = 1
    }
    { print }
    END { if (!done) exit 3 }' "$src" > "$tmp/mocked_store.go" || {
      echo "sqlmock-strict: could not find 'mockDB.Close()' inside 'return mockedStore, func() {' in tests/mocked_store.go;" \
           "the file changed shape - update this script" >&2; exit 2; }
fi
printf '{"Replace":{"%s":"%s"}}\n' "$src" "$tmp/mocked_store.go" > "$tmp/overlay.json"

# shellcheck source=/dev/null
source "$repo/.claude/skills/build-and-env/scripts/ep-env.sh" || { echo "sqlmock-strict: ep-env.sh failed" >&2; exit 2; }
cd "$ep"
mod="$(go list -m)"
set +e
go test -count=1 -json -overlay="$tmp/overlay.json" "${pkgs[@]}" > "$tmp/test.json" 2> "$tmp/test.err"
rc=$?
set -e
[ -s "$tmp/test.json" ] || { echo "sqlmock-strict: go test produced no output (exit $rc)" >&2; sed -n '1,20p' "$tmp/test.err" >&2; exit 2; }

# Failing tests (package-relative) and, per test, the unmet query patterns.
awk -v mod="$mod" '
  function field(name,   m) {
    if (match($0, "\"" name "\":\"[^\"]*\"")) { m = substr($0, RSTART, RLENGTH); sub("^\"" name "\":\"", "", m); sub("\"$", "", m); return m }
    return ""
  }
  {
    act = field("Action"); t = field("Test"); p = field("Package"); sub("^" mod "/?", "", p); if (p == "") p = "."
    if (act == "fail" && t != "") print "FAIL\t" p "\t" t
    if (act == "output" && t != "" && index($0, "matches sql:") > 0) {
      o = $0; sub(/.*matches sql: /, "", o); sub(/\\n".*$/, "", o); gsub(/\\"/, "\"", o); gsub(/\\\\/, "\\", o); print "SQL\t" p "\t" t "\t" o
    }
    if (act == "output" && t != "" && index($0, "SQLMOCK-STRICT") > 0) print "STRICT\t" p "\t" t
  }' "$tmp/test.json" > "$tmp/fails.tsv"

# Leaf failures only (a failing subtest also fails its parents).
awk -F'\t' '$1 == "FAIL" { n[NR] = $2 "\t" $3; all[$2 "\t" $3] = 1 }
  END { for (i in n) { x = n[i]; isparent = 0; for (y in all) if (index(y, x "/") == 1) isparent = 1; if (!isparent) print n[i] } }' \
  "$tmp/fails.tsv" | sort > "$tmp/leaves.tsv"

known=0; newunmet=0; other=0
while IFS=$'\t' read -r p t; do
  [ -n "$p" ] || continue
  strict=$(awk -F'\t' -v p="$p" -v t="$t" '$1 == "STRICT" && $2 == p && $3 == t { print; exit }' "$tmp/fails.tsv")
  sqls=$(awk -F'\t' -v p="$p" -v t="$t" '$1 == "SQL" && $2 == p && $3 == t { print $4 }' "$tmp/fails.tsv" | paste -sd ';' -)
  if [ -z "$strict" ]; then
    other=$((other + 1)); echo "FAIL  (not an sqlmock expectation) $p $t"
  elif in_list "$p $t" "${KNOWN_UNMET[@]}"; then
    known=$((known + 1)); echo "KNOWN unmet $p $t  -> ${sqls:-?}"
  else
    newunmet=$((newunmet + 1)); echo "NEW   unmet $p $t  -> ${sqls:-?}"
  fi
done < "$tmp/leaves.tsv"
for k in "${KNOWN_UNMET[@]}"; do
  grep -qF "\"Package\":\"$mod/${k%% *}\"" "$tmp/test.json" || continue   # package not in scope (-- <pkgs>)
  awk -F'\t' -v k="$k" '$1 " " $2 == k { f = 1 } END { exit !f }' "$tmp/leaves.tsv" || echo "INFO known unmet expectation no longer fails (fixed? update KNOWN_UNMET): $k"
done
okp=$(grep -cE '"Action":"pass","Package":"[^"]*","Elapsed"' "$tmp/test.json" || true)
echo "SUMMARY sqlmock-strict: $((known + newunmet)) unmet-expectation subtests ($known known, $newunmet new), $other other failures, $okp packages fully ok (go test exit $rc)"
if [ "$other" -gt 0 ] || [ "$newunmet" -gt 0 ]; then exit 1; fi
if [ "$all" = 1 ] && [ "$known" -gt 0 ]; then exit 1; fi
exit 0
