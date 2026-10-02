#!/usr/bin/env bash
# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# replay-on-lago.sh — acceptance gate of the scenario tier: every scenario is replayed on the reference (the oracle
# adapter's system.* ops) twice, each run in a fresh adapter process, then once more with one expected integer
# changed by +1 (mutation check), the scenarios with intermediate snapshot steps once more with those steps' expectations
# changed (step mutation check), and validated. A scenario is ACCEPTED only when both replays PASS, the mutated
# replays FAIL and the validator reports no error for its file.
#
# Usage:  ORACLE_DB=lago_api_test_<you> replay-on-lago.sh [--keep DIR] [scenario files...]
#         default files: every <skills>/billing-engine-spec/scenarios/scn.*.json
#         --keep DIR keeps the four JSON reports and the replay dumps (default: a mktemp dir, deleted on success)
# Output: ACCEPT <id> | REJECT <id> <reason> lines, then
#         SUMMARY replay-on-lago: scenarios=N accepted=N rejected=N
# Exit:   0 every scenario accepted; 3 some rejected; 2 setup error (oracle not ready); 1 usage.
#
# WARNING: system.reset wipes $ORACLE_DB (and, for store "ch" scenarios, the ClickHouse event tables under
# ch.lock). Use your own database. Writes only to the --keep/mktemp directory.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$HERE/../.." && pwd)                      # reimplementation-kit/
SKILLS=$(cd "$KIT/.." && pwd)
ORACLE="$HERE/oracle.sh"
keep=""
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep=$2; shift 2 ;;
    -h|--help) awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 1 ;;
    *) files+=("$1"); shift ;;
  esac
done
[ -n "${ORACLE_DB:-}" ] || { echo "set ORACLE_DB=lago_api_test_<you> (system.reset wipes it)" >&2; exit 1; }
if [ ${#files[@]} -eq 0 ]; then
  mapfile -t files < <(ls "$SKILLS"/billing-engine-spec/scenarios/scn.*.json 2>/dev/null | sort)
fi
[ ${#files[@]} -gt 0 ] || { echo "no scenario files" >&2; exit 1; }
st=$("$ORACLE" status 2>&1 || true)
grep -Eq "migrations=([0-9]+) want=\1\b" <<<"$st" || { echo "oracle database $ORACLE_DB not ready: run $ORACLE db" >&2; exit 2; }

if [ -n "$keep" ]; then out=$keep; mkdir -p "$out"; else out=$(mktemp -d); fi
replay() { # $1 = report name, rest = extra flags
  local name=$1; shift
  python3 "$KIT/scripts/scenario-replay.py" --impl-cmd "$ORACLE adapter" --scenarios "${files[@]}" \
    --report "$out/$name.json" --show-diff 3 --require-all "$@" > "$out/$name.txt" 2>&1 || true
}
replay run1 --dump "$out/dump1"
replay run2 --dump "$out/dump2"
replay mutate --mutate
replay mutsteps --mutate-steps
python3 "$KIT/scripts/validate-vectors.py" "${files[@]}" > "$out/validate.txt" 2>&1 || true

rc=0
python3 - "$out" "${files[@]}" <<'PY' || rc=$?
import json, os, sys
out, files = sys.argv[1], sys.argv[2:]
def load(n):
    p = os.path.join(out, n + ".json")
    if not os.path.exists(p):
        return {}
    with open(p) as f:
        return {s["id"]: s for s in json.load(f).get("scenarios", [])}
r1, r2, mu, ms = load("run1"), load("run2"), load("mutate"), load("mutsteps")
val = open(os.path.join(out, "validate.txt"), encoding="utf-8").read().splitlines()
acc = rej = 0
for f in files:
    sid = os.path.basename(f)[:-5]
    why = []
    for name, r in (("replay 1", r1), ("replay 2", r2)):
        s = r.get(sid, {}).get("status", "MISSING")
        if s != "PASS":
            d = (r.get(sid, {}).get("diffs") or [""])[0]
            why.append(f"{name} {s}: {d}"[:240])
    if mu.get(sid, {}).get("status") != "FAIL":
        why.append(f"mutation not detected ({mu.get(sid, {}).get('status', 'MISSING')})")
    with open(f, encoding="utf-8") as fh:
        has_snap = any(st.get("op") == "snapshot" for st in json.load(fh).get("steps", []))
    if has_snap and ms.get(sid, {}).get("status") != "FAIL":
        why.append(f"snapshot-step mutation not detected ({ms.get(sid, {}).get('status', 'MISSING')})")
    errs = [l for l in val if l.startswith("ERROR") and os.path.basename(f) in l]
    if errs:
        why.append(errs[0][:240])
    if why:
        rej += 1
        print(f"REJECT {sid} " + " | ".join(why))
    else:
        acc += 1
        print(f"ACCEPT {sid}")
print(f"SUMMARY replay-on-lago: scenarios={len(files)} accepted={acc} rejected={rej}")
sys.exit(0 if rej == 0 else 3)
PY
if [ $rc -eq 0 ] && [ -z "$keep" ]; then rm -rf "$out"; else echo "reports kept in $out" >&2; fi
exit $rc
