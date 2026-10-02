#!/usr/bin/env bash
# MAINTAINER-ONLY: needs the lago repository (events-processor tree 83e012866f29) and the Go/CGO toolchain; excluded from clean-room packs.
#
# regen-goldens.sh - re-mint the compat goldens from the Go reference with a reviewed diff.
#
# Usage: regen-goldens.sh [--mode db|cache|both] [--only REGEX] [--passes N] [--apply] [--tree TREE_ID]
#   --mode    which golden set (default both)
#   --only    regex on scenario names (default all)
#   --passes  observe each scenario N times (default 3); every pass must produce the same text
#             (compared as a multiset of lines, like the suite) or nothing is offered
#   --apply   copy the observed goldens over conformance/golden/compat-<mode>/ (only after you
#             reviewed the printed diff; commit them with the diff in the PR body)
#
# Steps: build-go-reference.sh -> run-suite.sh --profile compat --update --golden-dir <tmp>/passK
# for K=1..N -> pass-to-pass determinism check -> diff of pass 1 against the shipped goldens.
# Writes only under $LAGO_SKILLS_CACHE/epconf-regen/<UTC time>/ unless --apply.
# Exit: 0 no differences (or applied); 3 differences found (not applied) or passes disagree;
#       1 build/run failure; 2 usage.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill="$(dirname "$(dirname "$here")")"
cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
modes="db cache"; only='.'; passes=3; apply=0; tree_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) case "${2:?}" in both) modes="db cache" ;; db|cache) modes="$2" ;; *) echo "regen-goldens: bad --mode" >&2; exit 2 ;; esac; shift ;;
    --only) only="${2:?}"; shift ;;
    --passes) passes="${2:?}"; shift ;;
    --apply) apply=1 ;;
    --tree) tree_args=(--tree "${2:?}"); shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "regen-goldens: unknown argument $1" >&2; exit 2 ;;
  esac; shift
done
eval "$(bash "$here/build-go-reference.sh" ${tree_args[@]+"${tree_args[@]}"} --print-env)" || exit 1
out="$cache/epconf-regen/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"
rc=0; nondet=0
msort() { grep -v '^##' "$1" | sed 's/[ \r]*$//' | grep -v '^$' | sort; }
for mode in $modes; do
  mkdir -p "$out/$mode"
  for k in $(seq 1 "$passes"); do
    bash "$skill/scripts/run-suite.sh" --impl-cmd "$EP_REF_BIN" --impl-env "LD_LIBRARY_PATH=$EP_REF_LD_LIBRARY_PATH" \
      --mode "$mode" --profile compat --update --only "$only" --golden-dir "$out/$mode/pass$k" \
      --keep "$out/$mode/keep$k" > "$out/$mode/pass$k.log" 2>&1 || true
    grep -q 'exit=2' "$out/$mode/pass$k.log" && { echo "regen-goldens: setup error, see $out/$mode/pass$k.log" >&2; exit 1; }
  done
  for f in "$out/$mode/pass1"/*.golden; do
    b="$(basename "$f")"
    for k in $(seq 2 "$passes"); do
      if ! diff -q <(msort "$f") <(msort "$out/$mode/pass$k/$b") >/dev/null; then
        echo "NONDETERMINISTIC $mode $b (pass 1 vs pass $k)"; rc=3; nondet=1
      fi
    done
    shipped="$skill/conformance/golden/compat-$mode/$b"
    if [ ! -f "$shipped" ]; then echo "NEW $mode $b"; [ "$rc" = 0 ] && rc=3; continue; fi
    if ! diff -q <(msort "$shipped") <(msort "$f") >/dev/null; then
      echo "CHANGED $mode $b"; { diff <(msort "$shipped") <(msort "$f") || true; } | sed 's/^/    /' | head -40
      [ "$rc" = 0 ] && rc=3
    fi
  done
done
if [ "$rc" = 3 ] && [ "$apply" = 1 ] && [ "$nondet" = 1 ]; then
  echo "regen-goldens: passes disagree; nothing applied" >&2
elif [ "$rc" = 3 ] && [ "$apply" = 1 ]; then
  for mode in $modes; do cp "$out/$mode/pass1"/*.golden "$skill/conformance/golden/compat-$mode/"; done
  echo "regen-goldens: applied (review with git diff before committing)"; rc=0
fi
echo "regen-goldens: modes=[$modes] passes=$passes out=$out exit=$rc"
exit "$rc"
