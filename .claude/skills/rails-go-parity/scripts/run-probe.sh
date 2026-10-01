#!/usr/bin/env bash
# run-probe.sh — run one of this skill's Go parity probes against the CURRENT
# events-processor checkout without writing anything into the repository.
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/rails-go-parity/scripts/run-probe.sh time  [-base N] [-scan N] [-fail-on-mismatch]
#   .claude/skills/rails-go-parity/scripts/run-probe.sh value [-values-only]
#   .claude/skills/rails-go-parity/scripts/run-probe.sh subscription
#
#   time          utils.ToTime / ToFloat64Timestamp / CustomTime over "<sec>.<ms>" ms=0..999 (no CGO)
#   value         real EnrichEvent `value` string for a golden property corpus (CGO: sources
#                 build-and-env's ep-env.sh automatically if LAGO_EXPRESSION_LIB is unset)
#   subscription  Go DB mode vs Go cache mode vs Rails SQL on a throwaway Postgres database
#                 (DATABASE_URL, default postgres://lago:lago@localhost:5432/lago; role needs CREATEDB)
#
# How it stays read-only: go.mod/go.sum are copied to a mktemp dir and passed with
# `-modfile=<tmp>/go.mod -mod=mod`, so a dependency bump in events-processor/go.mod is absorbed
# in the temp copy instead of failing with "missing go.sum entry" or dirtying the skill dir.
# The probe binary is built into that temp dir and executed directly (not `go run`, which
# turns every non-zero exit into 1), then the temp dir is removed.
#
# Exit codes: the probe's own exit code (time: 1 = -fail-on-mismatch hit, 2 = bad flag;
#             value/subscription: 1 = setup error); 2 = usage error, go missing, or the
#             probe failed to build (e.g. your events-processor change does not compile).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="${1:-}"
case "$probe" in
  time) dir=time-precision-probe ;;
  value) dir=value-format-probe ;;
  subscription) dir=subscription-parity-probe ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  "") sed -n '2,24p' "$0" >&2; exit 2 ;;
  *) echo "run-probe: unknown probe '$probe' (time|value|subscription)" >&2; exit 2 ;;
esac
shift

command -v go >/dev/null 2>&1 || { echo "run-probe: go not found (see build-and-env)" >&2; exit 2; }

if [ "$probe" = value ] && [ -z "${LAGO_EXPRESSION_LIB:-}" ]; then
  repo="$(git -C "$here" rev-parse --show-toplevel)"
  pushd "$repo" >/dev/null
  # shellcheck source=/dev/null
  source .claude/skills/build-and-env/scripts/ep-env.sh || {
    echo "run-probe: ep-env.sh failed (see its message above)" >&2; exit 2; }
  popd >/dev/null
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/rgp-probe.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cp "$here/go.mod" "$here/go.sum" "$tmp/"

cd "$here"
if ! go build -modfile="$tmp/go.mod" -mod=mod -o "$tmp/probe" "./$dir"; then
  echo "run-probe: building $dir failed (see above; for 'value' the CGO env comes from ep-env.sh)" >&2
  exit 2
fi
set +e
"$tmp/probe" "$@"
rc=$?
set -e
exit "$rc"
