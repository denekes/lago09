#!/usr/bin/env bash
# run.sh — build and run one of this skill's Go probes against the CURRENT
# events-processor checkout, without writing anything into the repository or
# the skill directory.
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/event-accounting-campaign/scripts/run.sh accounting-probe [-mode db|cache] [-case A,B] [-list] [-db-url URL] [-timeout 20s] [-v]
#   .claude/skills/event-accounting-campaign/scripts/run.sh value-corpus [-mode all|value|time] [-ruby] [-ch-bin PATH] [-value JSON]... [-fail-on-mismatch] [-v]
#   .claude/skills/event-accounting-campaign/scripts/run.sh cache-bench [-n 1000000]
#   .claude/skills/event-accounting-campaign/scripts/run.sh --check      # go vet + gofmt -l + franz-go pin check
#
#   accounting-probe  kfake fault matrix through the REAL consumer group + processor. -mode db
#                     (default) needs Postgres at DATABASE_URL, default postgres://lago:lago@localhost:5432/lago,
#                     role with CREATEDB (a throwaway database is created and dropped); -mode cache
#                     runs memory-cache mode (production's mode, DECIDED OD-1) with a seeded cache, no Postgres
#   value-corpus      golden property corpus through the REAL unmarshal + EnrichEvent; Rails/PG
#                     expected column; ClickHouse Decimal(38,26) emulation; utils.ToTime ms count;
#                     -value (repeatable, needs ruby) triages one customer value instead of the corpus
#   cache-bench       memory-cache (badger) warm-up time, Go heap and RSS for N subscriptions (W6)
#
# How it stays read-only: go.mod/go.sum are copied to a mktemp dir and passed with
# -modfile=<tmp>/go.mod -mod=mod (a dependency bump in events-processor/go.mod is absorbed
# in the temp copy); the binary is built in that temp dir and executed directly (not
# `go run`, which turns every non-zero exit into 1); the temp dir is removed on exit.
# The CGO env (libexpression_go) comes from build-and-env's ep-env.sh.
#
# Evaluate a candidate change (yours or a reviewed PR's) without editing the repo:
# write the patched file to a temp dir and pass a `go build -overlay` map through GOFLAGS:
#   d=$(mktemp -d); cp events-processor/config/kafka/consumer.go "$d/"   # then edit "$d/consumer.go"
#   printf '{"Replace":{"%s":"%s"}}\n' "$PWD/events-processor/config/kafka/consumer.go" "$d/consumer.go" >"$d/overlay.json"
#   GOFLAGS=-overlay="$d/overlay.json" .claude/skills/event-accounting-campaign/scripts/run.sh accounting-probe
# (from the repo root; absolute paths in the map). Verified 2026-10-01: "commit every record"
# (the findMaxCommitableRecord branch made unreachable) -> UNACCOUNTED 5 -> 7, exit 7.
#
# Exit codes: the probe's own exit code (accounting-probe: 0 all accounted, 1..99 =
#             UNACCOUNTED rows, 100 setup error; value-corpus: 0, 1 = mismatches with
#             -fail-on-mismatch, 2 setup error; cache-bench: 0, 1 cache error, 2 bad
#             flag); 2 = usage, go missing, ep-env.sh failure
#             or build failure; 5 = --check found a problem.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="${1:-}"
case "$probe" in
  accounting-probe|value-corpus|cache-bench|--check) ;;
  -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
  "") sed -n '2,39p' "$0" >&2; exit 2 ;;
  *) echo "run.sh: unknown probe '$probe' (accounting-probe|value-corpus|cache-bench|--check)" >&2; exit 2 ;;
esac
shift

command -v go >/dev/null 2>&1 || { echo "run.sh: go not found (see build-and-env)" >&2; exit 2; }
repo="$(git -C "$here" rev-parse --show-toplevel)"
[ -d "$repo/.claude/skills/diagnostics-and-tooling/scripts/kfake-harness" ] || {
  echo "run.sh: missing diagnostics-and-tooling/scripts/kfake-harness (this module imports its kfx, fixture and pipeline packages)" >&2; exit 2; }

if [ -z "${LAGO_EXPRESSION_LIB:-}" ]; then
  pushd "$repo" >/dev/null
  # shellcheck source=/dev/null
  source .claude/skills/build-and-env/scripts/ep-env.sh || { echo "run.sh: ep-env.sh failed (see above)" >&2; exit 2; }
  popd >/dev/null
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/eac-probe.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cp "$here/go.mod" "$here/go.sum" "$tmp/"
cd "$here"

if [ "$probe" = --check ]; then
  bad=0
  go vet -modfile="$tmp/go.mod" -mod=mod ./... || bad=1
  fmt_out="$(gofmt -l .)"
  if [ -n "$fmt_out" ]; then echo "gofmt -l: $fmt_out" >&2; bad=1; fi
  want="$(cd "$repo/events-processor" && go list -m -f '{{.Version}}' github.com/twmb/franz-go)"
  got="$(go list -modfile="$tmp/go.mod" -mod=mod -m -f '{{.Version}}' github.com/twmb/franz-go)"
  echo "franz-go: events-processor=$want probe-module=$got" >&2
  [ "$want" = "$got" ] || bad=1
  if [ "$bad" = 0 ]; then echo "run.sh: check OK" >&2; exit 0; fi
  echo "run.sh: check FAILED" >&2; exit 5
fi

if ! go build -modfile="$tmp/go.mod" -mod=mod -o "$tmp/probe" "./$probe"; then
  echo "run.sh: building $probe failed (does your events-processor change compile? CGO env from ep-env.sh)" >&2
  exit 2
fi
set +e
"$tmp/probe" "$@"
rc=$?
set -e
exit "$rc"
