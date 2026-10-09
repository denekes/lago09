#!/usr/bin/env bash
# overlay-run.sh — run `go test` in events-processor with files added, replaced or
# deleted ONLY in the build view (go test -overlay). The repo is never written.
#
# Usage:
#   overlay-run.sh [--no-cgo] <target>=<source> [<target>=<source> ...] [-- go test args]
#
#   <target>  path of the file as the build should see it, relative to
#             events-processor/ (e.g. config/kafka/zz_probe_test.go); a leading
#             "events-processor/" or an absolute path is accepted too. It may not
#             exist (= add a file) or exist (= replace it).
#   <source>  the file whose content to use (any path, e.g. in $TMPDIR).
#             Empty (`<target>=`) means: build as if <target> did not exist.
#   go test args default to: -count=1 ./...
#   --no-cgo  do not source ep-env.sh (only for packages that do not link
#             libexpression_go: cache, config/..., models, utils)
#
# Examples (from the repo root):
#   S=.claude/skills/diagnostics-and-tooling/scripts
#   $S/overlay-run.sh --no-cgo config/kafka/zz_commit_prefix_test.go=$S/overlay-examples/commit_prefix_test.go \
#       -- -count=1 -v -run TestOverlayDemo ./config/kafka/
#
# Limits (go help build): overlays apply to compilation only — a running test
# that reads files from disk (os.ReadFile, testdata/) sees the real disk; an
# overlaid file cannot import a module events-processor does not already require
# ("no required module provides package ..."): use a scratch copy or a separate
# module. go test runs in events-processor/, so RELATIVE output paths
# (-coverprofile=c.out, -cpuprofile) would land there: pass absolute paths.
#
# Exit codes: the exit code of `go test`; 1 usage error; 4 the events-processor
# working tree changed during the run, ignored files included (e.g. a relative
# -coverprofile; the offending paths are printed).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
ep="$repo/events-processor"

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "overlay-run: jq not found (needed to write the overlay JSON)" >&2; exit 1; }

nocgo=0
maps=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-cgo) nocgo=1; shift ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *=*) maps+=("$1"); shift ;;
    *) echo "overlay-run: expected <target>=<source> or --, got '$1'" >&2; usage ;;
  esac
done
[ ${#maps[@]} -gt 0 ] || usage
[ $# -gt 0 ] || set -- -count=1 ./...

tmp="$(mktemp -d "${TMPDIR:-/tmp}/overlay-run.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
json="$tmp/overlay.json"

entries=()
for m in "${maps[@]}"; do
  target="${m%%=*}" source="${m#*=}"
  case "$target" in
    /*) ;;
    events-processor/*) target="$repo/$target" ;;
    *) target="$ep/$target" ;;
  esac
  case "$target" in "$ep"/*) ;; *) echo "overlay-run: target must be inside events-processor/: $target" >&2; exit 1 ;; esac
  if [ -n "$source" ]; then
    [ -f "$source" ] || { echo "overlay-run: source not found: $source" >&2; exit 1; }
    # Snapshot the source so later edits do not race the build.
    snap="$tmp/$(printf '%03d' ${#entries[@]})-$(basename "$source")"
    cp "$source" "$snap"
    source="$snap"
  fi
  entries+=("$(jq -n --arg t "$target" --arg s "$source" '{($t): $s}')")
done
printf '%s\n' "${entries[@]}" | jq -s '{Replace: (add)}' > "$json"
echo "overlay-run: overlay map (build view only):" >&2
jq -r --arg ep "$ep/" '.Replace | to_entries[] | "  \(.key | ltrimstr($ep)) <- \(if .value == "" then "(deleted)" else .value end)"' "$json" >&2

# --ignored: also catch ignored outputs (*.test, *.out, the binary) that plain
# `git status` hides (events-processor/.gitignore), e.g. a relative -coverprofile.
before="$(git -C "$repo" status --porcelain --ignored -- events-processor)"
if [ "$nocgo" = 0 ]; then
  cd "$repo"   # ep-env.sh finds the repo from the current directory
  # shellcheck source=/dev/null
  source "$repo/.claude/skills/build-and-env/scripts/ep-env.sh"
else
  unset CGO_LDFLAGS LD_LIBRARY_PATH
fi
set +e
(cd "$ep" && go test -overlay="$json" "$@")
rc=$?
set -e
after="$(git -C "$repo" status --porcelain --ignored -- events-processor)"
if [ "$before" != "$after" ]; then
  echo "overlay-run: ERROR events-processor working tree changed during the run (incl. ignored files):" >&2
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
  echo "overlay-run: write test outputs to absolute paths, e.g. -coverprofile=\"\$TMPDIR/c.out\"" >&2
  exit 4
fi
exit "$rc"
