#!/usr/bin/env bash
# kfake-run.sh — run a scenario of the kfake harness (Go module in ./kfake-harness)
# with the CGO environment set up. Builds the scenario binary into
# ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/kfake-harness-bin/<GOFLAGS hash>/
# (never into the repo or the skill dir) and execs it, so the scenario's own
# exit code reaches the caller. (`go run` would turn every non-zero exit into 1;
# a persistent output path lets `go build` skip the relink when nothing changed.)
#
# Usage:
#   kfake-run.sh <scenario> [scenario flags]   # go build ./cmd/<scenario> (to the cache dir), then run it
#   kfake-run.sh --list                        # list scenarios
#   kfake-run.sh --check                       # go vet + gofmt -l + franz-go pin check on the module
#
# Scenarios (see reference/kfake-technique.md):
#   happy-path   N valid events through the REAL consumer group + processor (in-process)
#   cdc-brokers  memory-cache CDC consumers vs a comma-separated broker list
#   smoke        drive a BUILT binary (use smoke-binary.sh, which builds it first)
#
# Exit codes: the scenario's exit code (happy-path: 0 PASS, 1 FAIL, 2 setup error;
#             66 = data race found under GOFLAGS=-race); 1 usage / unknown scenario;
#             2 environment, setup or build error; 5 --check found a problem.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
mod="$here/kfake-harness"
orig="$PWD"

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0" >&2; exit 1; }
[ $# -ge 1 ] || usage

case "$1" in
  -h|--help) usage ;;
  --list) (cd "$mod/cmd" && ls -1); exit 0 ;;
esac

cd "$repo"   # ep-env.sh finds the repo from the current directory
# shellcheck source=/dev/null
source "$repo/.claude/skills/build-and-env/scripts/ep-env.sh" || exit 2
cd "$mod"

if [ "$1" = --check ]; then
  bad=0
  go vet ./... || bad=1
  fmt_out="$(gofmt -l .)"
  if [ -n "$fmt_out" ]; then echo "gofmt -l: $fmt_out" >&2; bad=1; fi
  want="$(cd "$repo/events-processor" && go list -m -f '{{.Version}}' github.com/twmb/franz-go)"
  got="$(go list -m -f '{{.Version}}' github.com/twmb/franz-go)"
  echo "franz-go: events-processor=$want harness=$got" >&2
  [ "$want" = "$got" ] || bad=1
  [ "$bad" = 0 ] && echo "kfake-run: check OK" >&2 && exit 0
  echo "kfake-run: check FAILED" >&2; exit 5
fi

scenario="$1"; shift
[ -d "cmd/$scenario" ] || { echo "kfake-run: unknown scenario '$scenario' (try --list)" >&2; exit 1; }
cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
bindir="$cache/kfake-harness-bin/$(printf '%s' "${GOFLAGS:-}" | cksum | cut -d' ' -f1)"
mkdir -p "$bindir" || exit 2
go build -o "$bindir/$scenario" "./cmd/$scenario" || { echo "kfake-run: build of cmd/$scenario failed" >&2; exit 2; }
# Run from the caller's directory: relative paths in scenario flags
# (-cpuprofile, -bin, -log, -expected) resolve there, never in the skill dir.
cd "$orig"
exec "$bindir/$scenario" "$@"
