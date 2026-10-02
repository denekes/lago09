#!/usr/bin/env bash
# kit-selftest.sh — self-test of the re-implementation kit's tooling (no lago source needed).
#
# Usage: kit-selftest.sh [--kit-root DIR] [--skip-kit-validate] [--skip-ep-build]
#
# Steps (one line each: SELFTEST <step> PASS|FAIL|SKIP <detail>):
#   syntax         bash -n on every *.sh of the kit skills; python3 -m py_compile (in memory) on every *.py
#   unit           scripts/selftest/test_runner.py: compare engine, literal forwarding, crash/timeout/garbage/
#                  wrong-id adapters, setup errors, restart limit, exit codes 0/2/3/4, parallel, report schema
#   validate-own   validate-vectors.py on reimplementation-kit/selftest/*.jsonl (0 errors)
#   validate-kit   validate-vectors.py on the whole kit (0 errors)                      [--skip-kit-validate]
#   selftest-pass  kitrun vs maintainer/selftest-adapter.py, both profiles: 100 % PASS   [maintainer checkout only]
#   selftest-mutate same with --mutate: >= 99 % of graded vectors FAIL                   [maintainer checkout only]
#   ep-build       go build of a temp copy of events-processor-spec/scripts/runner (if present, Go installed) [--skip-ep-build]
# Prints `SUMMARY kit-selftest: steps=N pass=N fail=N skip=N`.
# Exit: 0 no step failed; 1 a step failed; 2 usage error.
# Writes only to a mktemp -d directory (removed at exit).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SKIP_KIT=0 SKIP_EP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --kit-root) ROOT=$(cd "$2" && pwd); shift 2 ;;
    --skip-kit-validate) SKIP_KIT=1; shift ;;
    --skip-ep-build) SKIP_EP=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
RK=$ROOT/reimplementation-kit
[ -d "$RK/scripts" ] || { echo "no reimplementation-kit under $ROOT" >&2; exit 2; }
export PYTHONDONTWRITEBYTECODE=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0 SKIP=0
res() { # step status detail
  printf 'SELFTEST %-15s %s %s\n' "$1" "$2" "$3"
  case "$2" in PASS) PASS=$((PASS + 1)) ;; FAIL) FAIL=$((FAIL + 1)) ;; *) SKIP=$((SKIP + 1)) ;; esac
}

# syntax --------------------------------------------------------------------------------------------------------
bad=0; n=0
while IFS= read -r f; do n=$((n + 1)); bash -n "$f" 2>"$TMP/err" || { bad=$((bad + 1)); sed 's/^/    /' "$TMP/err"; }; done \
  < <(find "$ROOT/reimplementation-kit" "$ROOT/billing-engine-spec" "$ROOT/events-processor-spec" -name '*.sh' 2>/dev/null | sort)
while IFS= read -r f; do n=$((n + 1)); python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" 2>"$TMP/err" || { bad=$((bad + 1)); sed 's/^/    /' "$TMP/err"; }; done \
  < <(find "$ROOT/reimplementation-kit" "$ROOT/billing-engine-spec" "$ROOT/events-processor-spec" -name '*.py' 2>/dev/null | sort)
[ "$bad" = 0 ] && res syntax PASS "$n scripts parse" || res syntax FAIL "$bad of $n scripts do not parse"

# unit ------------------------------------------------------------------------------------------------------------
if python3 "$RK/scripts/selftest/test_runner.py" > "$TMP/unit.txt" 2>&1; then
  res unit PASS "$(grep -Eo 'Ran [0-9]+ tests' "$TMP/unit.txt")"
else
  sed 's/^/    /' "$TMP/unit.txt" | tail -30; res unit FAIL "$(tail -1 "$TMP/unit.txt")"
fi

# validate-own ----------------------------------------------------------------------------------------------------
own=( "$RK"/selftest/*.jsonl )
if [ -e "${own[0]}" ]; then
  if python3 "$RK/scripts/validate-vectors.py" --kit-root "$ROOT" --quiet "${own[@]}" > "$TMP/vo.txt" 2>&1; then
    res validate-own PASS "$(grep '^SUMMARY' "$TMP/vo.txt" | sed 's/SUMMARY validate-vectors: //')"
  else
    grep -v '^SIZES' "$TMP/vo.txt" | sed 's/^/    /' | tail -20; res validate-own FAIL "$(grep '^SUMMARY' "$TMP/vo.txt")"
  fi
else
  res validate-own SKIP "no reimplementation-kit/selftest/*.jsonl"
fi

# validate-kit ----------------------------------------------------------------------------------------------------
if [ "$SKIP_KIT" = 1 ]; then
  res validate-kit SKIP "--skip-kit-validate"
elif python3 "$RK/scripts/validate-vectors.py" --kit-root "$ROOT" --quiet > "$TMP/vk.txt" 2>&1; then
  res validate-kit PASS "$(grep '^SUMMARY' "$TMP/vk.txt" | sed 's/SUMMARY validate-vectors: //')"
else
  grep -v '^SIZES' "$TMP/vk.txt" | sed 's/^/    /' | tail -20; res validate-kit FAIL "$(grep '^SUMMARY' "$TMP/vk.txt" | sed 's/SUMMARY validate-vectors: //')"
fi

# selftest adapter (maintainer checkout only) --------------------------------------------------------------------
SA=$RK/scripts/maintainer/selftest-adapter.py
mapfile -t vfiles < <(find "$ROOT"/*/vectors "$RK/selftest" -maxdepth 1 -name '*.jsonl' 2>/dev/null | sort)
if [ ! -f "$SA" ]; then
  res selftest-pass SKIP "maintainer/selftest-adapter.py not in this pack"
  res selftest-mutate SKIP "maintainer/selftest-adapter.py not in this pack"
elif [ ${#vfiles[@]} = 0 ]; then
  res selftest-pass SKIP "no vector files"; res selftest-mutate SKIP "no vector files"
else
  okp=1 detail="" mdetail="" okm=1
  for prof in compat corrected; do
    python3 "$RK/scripts/kitrun.py" --kit-root "$ROOT" --vectors "${vfiles[@]}" --profile "$prof" --quiet --parallel 2 \
      --report "$TMP/p-$prof.json" --impl-cmd "python3 $SA --vectors ${vfiles[*]}" > "$TMP/p-$prof.txt" 2>&1 || true
    s=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); v=[x for x in r["vectors"] if x["status"]!="UNRULED"]; p=sum(x["status"]=="PASS" for x in v); u=[x for x in r["vectors"] if x["status"]=="UNRULED"]; up=sum(x.get("unruled_outcome")=="PASS" for x in u); print(p, len(v), up, len(u))' "$TMP/p-$prof.json")
    read -r p t up ut <<<"$s"
    detail+="$prof $p/$t (+unruled $up/$ut) "
    [ "$p" = "$t" ] && [ "$up" = "$ut" ] || okp=0
    python3 "$RK/scripts/kitrun.py" --kit-root "$ROOT" --vectors "${vfiles[@]}" --profile "$prof" --quiet --parallel 2 \
      --report "$TMP/m-$prof.json" --impl-cmd "python3 $SA --mutate --vectors ${vfiles[*]}" > "$TMP/m-$prof.txt" 2>&1 || true
    s=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); v=[x for x in r["vectors"] if x["status"]!="UNRULED"]; f=sum(x["status"]=="FAIL" for x in v); print(f, len(v), "ok" if not v or f/len(v)>=0.99 else "low"); [print("    not detected:", x["id"]) for x in v if x["status"]!="FAIL"][:0]' "$TMP/m-$prof.json")
    read -r f t verdict <<<"$s"
    mdetail+="$prof $f/$t "
    [ "$verdict" = ok ] || okm=0
  done
  [ "$okp" = 1 ] && res selftest-pass PASS "$detail" || { grep -v '^PASS' "$TMP"/p-*.txt | head -20 | sed 's/^/    /'; res selftest-pass FAIL "$detail"; }
  [ "$okm" = 1 ] && res selftest-mutate PASS "detected $mdetail" || res selftest-mutate FAIL "detected $mdetail(need >= 99 %)"
fi

# EP runner build -------------------------------------------------------------------------------------------------
RUNNER=$ROOT/events-processor-spec/scripts/runner
if [ "$SKIP_EP" = 1 ]; then
  res ep-build SKIP "--skip-ep-build"
elif [ ! -f "$RUNNER/go.mod" ]; then
  res ep-build SKIP "events-processor-spec/scripts/runner not present"
elif ! command -v go >/dev/null 2>&1; then
  res ep-build SKIP "go not installed"
elif cp -r "$RUNNER" "$TMP/runner-src" && (cd "$TMP/runner-src" && go build -o "$TMP/epconf" . > "$TMP/go.txt" 2>&1); then
  res ep-build PASS "epconf builds ($(du -h "$TMP/epconf" | cut -f1))"
else
  sed 's/^/    /' "$TMP/go.txt" | tail -10; res ep-build FAIL "go build failed"
fi

echo "SUMMARY kit-selftest: steps=$((PASS + FAIL + SKIP)) pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" = 0 ]
