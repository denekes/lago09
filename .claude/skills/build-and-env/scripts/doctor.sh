#!/usr/bin/env bash
# doctor.sh — read-only environment report for working on the lago umbrella repo.
# Prints one line per check: OK / WARN / FAIL / INFO. Never modifies anything.
# Usage: doctor.sh            Exit code: number of FAIL lines (0 = ready to run ep-test.sh).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
ok()   { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails+1)); }
info() { printf 'INFO  %s\n' "$*"; }

repo="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)" || { fail "not inside a git checkout"; exit 1; }
ok "repo root: $repo (HEAD $(git -C "$repo" rev-parse --short HEAD))"
if [ "$(git -C "$repo" rev-parse --is-shallow-repository)" = "true" ]; then
  warn "working clone is SHALLOW ($(git -C "$repo" rev-list --count HEAD) commits): use research-methodology/scripts/history-setup.sh for history"
else
  ok "working clone has full history ($(git -C "$repo" rev-list --count HEAD) commits)"
fi
for sm in api front; do
  pin="$(git -C "$repo" ls-tree HEAD "$sm" | awk '{print $3}')"
  if [ -n "$(ls -A "$repo/$sm" 2>/dev/null)" ]; then
    ok "submodule $sm populated (pinned ${pin:0:12})"
  else
    info "submodule $sm EMPTY (pinned ${pin:0:12}); read it via research-methodology/scripts/pinned-checkout.sh $sm"
  fi
done

# Go toolchain (go.mod pins the version; GOTOOLCHAIN=auto downloads it)
if command -v go >/dev/null 2>&1; then
  want="$(sed -nE 's/^go ([0-9.]+)$/\1/p' "$repo/events-processor/go.mod")"
  have="$(cd "$repo/events-processor" && go env GOVERSION 2>/dev/null)"
  if [ -n "$have" ]; then ok "go: events-processor resolves to $have (go.mod minimum: go $want; GOTOOLCHAIN=$(go env GOTOOLCHAIN))"
  else fail "go: could not resolve toolchain go $want (offline? install Go >= $want or set GOTOOLCHAIN)"; fi
else
  fail "go not on PATH"
fi

command -v cargo >/dev/null 2>&1 && ok "cargo: $(cargo --version 2>/dev/null)" || warn "cargo missing: needed once to build libexpression_go.so (or use ep-test.sh --no-cgo)"

cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
ref="$(sed -nE 's/.*git checkout (v[0-9][0-9.]*).*/\1/p' "$repo/events-processor/Dockerfile" | head -n1)"
so="$cache/lago-expression-$ref/target/release/libexpression_go.so"
if [ -f "$so" ]; then ok "libexpression_go.so cached for lago-expression $ref: $so"
else warn "libexpression_go.so not built yet for $ref (first 'source ep-env.sh' builds it into $cache)"; fi

dburl="${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}"
if command -v pg_isready >/dev/null 2>&1; then
  if pg_isready -q -d "$dburl"; then ok "postgres reachable: $dburl"
  else warn "postgres NOT reachable at $dburl (only config/database tests need it; see build-and-env SKILL.md)"; fi
else
  warn "pg_isready not installed; cannot check Postgres"
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then ok "docker daemon reachable (dev stack possible)"
  else info "docker CLI present but NO daemon: 'docker compose config' works, 'up'/'exec' do not"; fi
else
  info "docker not installed"
fi

lt="$(type -t lago 2>/dev/null || true)"
case "$lt" in
  alias)    info "'lago' is a shell alias (docs/dev_environment.md style)";;
  file)     warn "'lago' on PATH is a binary ($(command -v lago)): probably getlago/lago-cli, which has NO 'exec' subcommand";;
  *)        info "'lago' not defined in this shell: use 'docker compose -f docker-compose.dev.yml ...' directly";;
esac

command -v golangci-lint >/dev/null 2>&1 && ok "golangci-lint: $(golangci-lint version 2>/dev/null | head -n1)" || info "golangci-lint not installed"

[ -d "$cache/lago-history.git" ] && ok "history clone: $cache/lago-history.git ($(git -C "$cache/lago-history.git" rev-list --count HEAD 2>/dev/null) commits)" || info "no history clone yet (research-methodology/scripts/history-setup.sh)"
for d in "$cache"/lago-api@* "$cache"/lago-front@*; do [ -d "$d" ] && info "pinned checkout: $d"; done

echo "doctor: $fails FAIL(s)"
exit "$fails"
