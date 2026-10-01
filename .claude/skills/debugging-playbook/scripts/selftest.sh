#!/usr/bin/env bash
# selftest.sh - verify the debugging-playbook scripts: bash syntax, the pattern database
# (explain-error.sh --self-test), exit codes, and triage-ep-log.sh output on the bundled log
# samples (testdata/<name>.log, real 2026-10-01 runs plus one synthetic file) against
# testdata/<name>.expected.
#
# Usage: selftest.sh [--update]
#   --update  rewrite testdata/*.expected from the current output (then REVIEW the git diff)
# Exit codes: 0 all checks pass; 1 at least one check failed; 2 usage error
# Also re-runs every bundled log with `docker compose logs` / `kubectl logs --timestamps` prefixes
# (in a mktemp -d dir, removed on exit) and requires the same triage report.
# Read-only unless --update (which writes only testdata/*.expected). No network, no Docker.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
update=0
case "${1:-}" in
  '') ;;
  --update) update=1 ;;
  -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
  *) echo "selftest: unknown argument $1" >&2; exit 2 ;;
esac

fail=0 pass=0
ok() { pass=$((pass + 1)); echo "PASS $*"; }
ko() { fail=$((fail + 1)); echo "FAIL $*"; }

for s in explain-error.sh triage-ep-log.sh selftest.sh; do
  if bash -n "$here/$s"; then ok "bash -n $s"; else ko "bash -n $s"; fi
done

if out=$("$here/explain-error.sh" --self-test); then ok "explain-error --self-test: $out"; else ko "explain-error --self-test"; echo "$out"; fi

rc=0; "$here/explain-error.sh" 'panic: brokers not found' >/dev/null || rc=$?
[ $rc -eq 0 ] && ok "explain-error known string -> exit 0" || ko "explain-error known string -> exit $rc"
rc=0; "$here/explain-error.sh" 'zz no such failure zz' >/dev/null 2>&1 || rc=$?
[ $rc -eq 1 ] && ok "explain-error unknown string -> exit 1" || ko "explain-error unknown string -> exit $rc (want 1)"
rc=0; "$here/explain-error.sh" >/dev/null 2>&1 || rc=$?
[ $rc -eq 2 ] && ok "explain-error no argument -> exit 2" || ko "explain-error no argument -> exit $rc (want 2)"

for log in "$here"/testdata/*.log; do
  name="$(basename "$log" .log)"
  exp="$here/testdata/$name.expected"
  got="$("$here/triage-ep-log.sh" "$log" 2>&1)" || true
  if [ $update -eq 1 ]; then printf '%s\n' "$got" > "$exp"; ok "updated $name.expected"; continue; fi
  if [ ! -f "$exp" ]; then ko "missing $name.expected (run --update)"; continue; fi
  if diff -u "$exp" <(printf '%s\n' "$got") > /dev/null; then ok "triage $name.log matches expected"
  else ko "triage $name.log differs:"; diff -u "$exp" <(printf '%s\n' "$got") | head -40 || true; fi
done

# collector prefixes: every bundled log, re-prefixed the way `docker compose logs` and
# `kubectl logs --timestamps` print it, must triage exactly like the bare log (header line aside)
if [ $update -eq 0 ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dp-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  for style in compose kubectl; do
    bad=""
    for log in "$here"/testdata/*.log; do
      name="$(basename "$log" .log)"
      if [ "$style" = compose ]; then
        awk '/^#/ {print; next} {print "lago_events-processor  | " $0}' "$log" > "$tmp/$name.log"
      else
        awk '/^#/ {print; next} {print "2026-10-01T21:40:20.994900056Z " $0}' "$log" > "$tmp/$name.log"
      fi
      want="$("$here/triage-ep-log.sh" "$log" 2>&1 | tail -n +2)" || true
      got="$("$here/triage-ep-log.sh" "$tmp/$name.log" 2>&1 | tail -n +2)" || true
      [ "$want" = "$got" ] || bad="$bad $name"
    done
    if [ -z "$bad" ]; then ok "triage with $style prefixes == bare logs"; else ko "triage with $style prefixes differs for:$bad"; fi
  done
fi

rc=0; "$here/triage-ep-log.sh" --fail-on-findings "$here/testdata/synthetic.log" >/dev/null || rc=$?
[ $rc -eq 3 ] && ok "triage --fail-on-findings -> exit 3" || ko "triage --fail-on-findings -> exit $rc (want 3)"
rc=0; printf 'not a log\n' | "$here/triage-ep-log.sh" - >/dev/null 2>&1 || rc=$?
[ $rc -eq 1 ] && ok "triage non-EP input -> exit 1" || ko "triage non-EP input -> exit $rc (want 1)"

echo "selftest: $pass passed, $fail failed"
[ $fail -eq 0 ]
