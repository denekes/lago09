#!/usr/bin/env bash
# ep-test.sh — run the events-processor Go tests without Docker.
# Mirrors .github/workflows/events-processor-tests.yml (which builds libexpression_go.so
# and runs `go test -v ./...` against a Postgres service).
#
# Usage:
#   ep-test.sh                      # go test -count=1 ./...   (full suite, needs Postgres)
#   ep-test.sh -v -run TestFoo ./processors/...   # any `go test` args are passed through
#   ep-test.sh --no-cgo [args]      # only packages that do NOT link libexpression_go
#                                   # (no Rust/cargo needed; skips processors/events_processor)
# Env: DATABASE_URL (default postgres://lago:lago@localhost:5432/lago), LAGO_SKILLS_CACHE.
# Exit code: that of `go test`.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
cd "$repo/events-processor"

nocgo=0
if [ "${1:-}" = "--no-cgo" ]; then nocgo=1; shift; fi

export DATABASE_URL="${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}"
if command -v pg_isready >/dev/null 2>&1 && ! pg_isready -q -d "$DATABASE_URL"; then
  echo "ep-test: WARNING Postgres not reachable at $DATABASE_URL -" \
       "config/database TestNewConnection will FAIL with a nil-pointer panic." \
       "See build-and-env SKILL.md 'Postgres for tests'." >&2
fi

if [ "$nocgo" = 1 ]; then
  pkgs=()
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    deps="$(go list -test -deps "$p" 2>/dev/null || true)"
    case "$deps" in
      *lago-expression/expression-go*) ;;   # links libexpression_go: skip
      *) pkgs+=("$p") ;;
    esac
  done < <(go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}{{end}}' ./...)
  echo "ep-test: --no-cgo packages: ${pkgs[*]}" >&2
  unset CGO_LDFLAGS LD_LIBRARY_PATH
  [ $# -eq 0 ] && set -- -count=1
  exec go test "$@" "${pkgs[@]}"
fi

# shellcheck source=ep-env.sh
source "$here/ep-env.sh"
[ $# -eq 0 ] && set -- -count=1 ./...
exec go test "$@"
