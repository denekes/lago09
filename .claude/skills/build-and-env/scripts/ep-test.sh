#!/usr/bin/env bash
# ep-test.sh — run the events-processor Go tests without Docker.
# Same shape as .github/workflows/events-processor-tests.yml (host-built libexpression_go.so,
# plain `go test ./...` against Postgres), not identical: CI builds the whole lago-expression
# workspace with the runner's unpinned Rust and uses a postgres:14 service; this builds only
# expression-go/ with local cargo and uses the local Postgres.
#
# Usage:
#   ep-test.sh                      # go test -count=1 ./...   (full suite, needs Postgres)
#   ep-test.sh -v -run TestFoo ./processors/...   # any `go test` args are passed through
#   ep-test.sh -race -count=1       # flags but NO package: ./... is added (with a note on
#                                   # stderr); plain `go test -race` would test only the root
#                                   # package, which has no tests, and exit 0
#   ep-test.sh --no-cgo [flags]     # only packages that do NOT link libexpression_go
#                                   # (no Rust/cargo needed; skips processors/events_processor)
#                                   # The 5 package paths are always appended: pass go test
#                                   # FLAGS here (-v, -run X), not package patterns.
# Package paths are relative to events-processor/ (the script cd's there).
# Env: DATABASE_URL (default postgres://lago:lago@localhost:5432/lago), LAGO_SKILLS_CACHE.
# Exit code: that of `go test` (1 if ep-env.sh fails to set up the CGO env).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
cd "$repo/events-processor"

nocgo=0
if [ "${1:-}" = "--no-cgo" ]; then nocgo=1; shift; fi

export DATABASE_URL="${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}"
if command -v pg_isready >/dev/null 2>&1 && ! pg_isready -q -d "$DATABASE_URL"; then
  echo "ep-test: WARNING Postgres not reachable at $(printf '%s' "$DATABASE_URL" | sed -E 's#(://[^:/@]+:)[^@]*@#\1***@#') -" \
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
# Is any argument a package pattern? Skip the value of go test flags that take one
# (`-run X`, `-count 1`, ...); `-flag=value` is a single token. Stop at -args.
has_pkg=0; skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -args|--args) break ;;
    -*=*) ;;
    -run|--run|-skip|--skip|-count|--count|-timeout|--timeout|-cpu|--cpu|-parallel|--parallel|\
    -coverprofile|--coverprofile|-coverpkg|--coverpkg|-covermode|--covermode|-bench|--bench|\
    -benchtime|--benchtime|-blockprofile|--blockprofile|-cpuprofile|--cpuprofile|\
    -memprofile|--memprofile|-mutexprofile|--mutexprofile|-outputdir|--outputdir|-trace|--trace|\
    -tags|--tags|-shuffle|--shuffle|-o|--o|-exec|--exec|-fuzz|--fuzz|-fuzztime|--fuzztime|\
    -list|--list|-vet|--vet|-p|--p|-gcflags|--gcflags|-ldflags|--ldflags|-mod|--mod|\
    -overlay|--overlay|-modfile|--modfile|-toolexec|--toolexec|-pkgdir|--pkgdir|-C|--C) skip=1 ;;
    -*) ;;
    *) has_pkg=1; break ;;
  esac
done
if [ "$has_pkg" = 0 ]; then
  echo "ep-test: no package pattern given; testing ./..." >&2
  set -- ./... "$@"
fi
exec go test "$@"
