#!/usr/bin/env bash
# doctor.sh — read-only environment report for working on the lago umbrella repo.
# Prints one line per check: OK / WARN / FAIL / INFO. Never writes to the repo.
# Side effect outside the repo: the `go env` probe in events-processor/ obeys
# GOTOOLCHAIN=auto, so on a host without go1.25.0 cached the first run downloads that
# toolchain (~214 MB) into $(go env GOMODCACHE), exactly like any other go command there.
# Usage: doctor.sh            Exit code: number of FAIL lines (0 = ready to run ep-test.sh).
# Env: DATABASE_URL (default postgres://lago:lago@localhost:5432/lago), LAGO_SKILLS_CACHE.
# No `set -e` on purpose: every check must run even when an earlier one fails.
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
  if [ -n "$have" ]; then
    ok "go: events-processor resolves to $have (go.mod minimum: go $want; GOTOOLCHAIN=$(go env GOTOOLCHAIN))"
    # Go turns cgo off silently when no C compiler is on PATH (or CGO_ENABLED=0 is set);
    # the expression wrapper then fails with "build constraints exclude all Go files".
    cgo="$(cd "$repo/events-processor" && go env CGO_ENABLED 2>/dev/null || true)"
    if [ "$cgo" = "1" ]; then ok "cgo enabled (CC=$(cd "$repo/events-processor" && go env CC 2>/dev/null))"
    else fail "cgo DISABLED (CGO_ENABLED=${cgo:-?}): install gcc (e.g. build-essential) and unset CGO_ENABLED; processors/events_processor cannot build"; fi
  else
    fail "go: could not resolve toolchain go $want (offline? install Go >= $want or set GOTOOLCHAIN)"
  fi
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
# Never print a password (change-control N11): show user:***@ instead.
dbshow="$(printf '%s' "$dburl" | sed -E 's#(://[^:/@]+:)[^@]*@#\1***@#')"
if command -v pg_isready >/dev/null 2>&1; then
  if pg_isready -q -d "$dburl"; then
    # pg_isready says "accepting connections" even when the role/db/password is wrong.
    if ! command -v psql >/dev/null 2>&1; then ok "postgres reachable: $dbshow (psql missing: login not checked)"
    # -w: never prompt for a password (a prompt on /dev/tty would hang an interactive run).
    elif PGCONNECT_TIMEOUT=5 psql -w "$dburl" -XAtqc 'select 1' >/dev/null 2>&1; then ok "postgres reachable and login works: $dbshow"
    else warn "postgres accepts connections but login FAILED at $dbshow (role/db missing or wrong password; see build-and-env SKILL.md 'Postgres for tests')"; fi
  else warn "postgres NOT reachable at $dbshow (only config/database tests need it; see build-and-env SKILL.md 'Postgres for tests')"; fi
else
  warn "pg_isready not installed; cannot check Postgres"
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then ok "docker daemon reachable (dev stack possible)"
  else info "docker CLI present but NO daemon: 'docker compose config' works, 'up'/'exec' do not"; fi
else
  info "docker not installed"
fi

# An executed script never inherits the caller's aliases (`type -t lago` can never say
# "alias" here), so check (a) a binary on PATH and (b) alias definitions in rc files.
lbin="$(type -P lago 2>/dev/null || true)"
[ -n "$lbin" ] && warn "'lago' on PATH is a binary ($lbin): probably getlago/lago-cli, which has NO 'exec'/'up' subcommand (Error: unknown command \"exec\" for \"lago\")"
lrc=""
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
  [ -f "$rc" ] && grep -qE '^[[:space:]]*alias[[:space:]]+lago[=[:space:]]' "$rc" && lrc="$lrc $rc"
done
if [ -n "$lrc" ]; then
  info "'lago' alias defined in:$lrc (interactive shells only; agent/CI shells never load it)"
elif [ -z "$lbin" ]; then
  info "'lago' not defined (no binary, no rc alias): use 'docker compose -f docker-compose.dev.yml ...' or build-and-env/scripts/dc.sh"
fi

command -v golangci-lint >/dev/null 2>&1 && ok "golangci-lint: $(golangci-lint version 2>/dev/null | head -n1)" || info "golangci-lint not installed"

[ -d "$cache/lago-history.git" ] && ok "history clone: $cache/lago-history.git ($(git -C "$cache/lago-history.git" rev-list --count HEAD 2>/dev/null) commits)" || info "no history clone yet (research-methodology/scripts/history-setup.sh)"
for d in "$cache"/lago-api@* "$cache"/lago-front@*; do [ -d "$d" ] && info "pinned checkout: $d"; done

echo "doctor: $fails FAIL(s)"
exit "$fails"
