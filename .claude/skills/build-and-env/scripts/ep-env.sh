#!/usr/bin/env bash
# (sourced file: deliberately no `set -euo pipefail`, it would leak into the caller's shell)
# shellcheck shell=bash
# ep-env.sh — make `go build` / `go test` work in events-processor WITHOUT Docker.
#
# SOURCE it (do not execute it):
#     source .claude/skills/build-and-env/scripts/ep-env.sh
# Repo used: the lago checkout containing the current directory (so it also serves another
# clone you cd into); if the cwd is outside any lago checkout, the checkout containing this
# script. Sourcing by absolute path from anywhere therefore works.
#
# What it does:
#   1. Reads the lago-expression ref pinned in events-processor/Dockerfile
#      (the `git checkout vX.Y.Z` line), unless LAGO_EXPRESSION_REF is already set.
#   2. If $LAGO_SKILLS_CACHE/lago-expression-<ref>/target/release/libexpression_go.so
#      is missing, shallow-clones getlago/lago-expression at that ref and runs
#      `cargo build --release` in expression-go/ (first run ~40 s; needs cargo + network).
#   3. Exports CGO_LDFLAGS (link-time search path) and LD_LIBRARY_PATH (run-time
#      loader path) pointing at that directory, plus DATABASE_URL if unset.
#
# It never writes inside the repository. Cache dir: ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}
# Exported: LAGO_REPO LAGO_SKILLS_CACHE LAGO_EXPRESSION_REF LAGO_EXPRESSION_LIB
#           CGO_LDFLAGS LD_LIBRARY_PATH DATABASE_URL
# Status: 0 = exported; 1 = lago repo not found / ref unreadable / cargo missing /
#         clone or cargo build failed (nothing exported). Executed instead of sourced: exit 2.
# Needed by `go build` and `go test` of packages that link libexpression_go
# (only processors/events_processor has tests). `go vet` and golangci-lint do NOT need it.
# Override the ref to test a bump: LAGO_EXPRESSION_REF=vX.Y.Z source .../ep-env.sh

_lago_ep_env() {
  local repo ref cache src lib
  # cwd's checkout first (keeps "source it inside another clone" working), else this script's own.
  repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$repo" ] || [ ! -f "$repo/events-processor/Dockerfile" ]; then
    repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null)" || {
      echo "ep-env: cannot locate the lago repo (cwd and script location are not in a lago checkout)" >&2; return 1; }
  fi
  if [ ! -f "$repo/events-processor/Dockerfile" ]; then
    echo "ep-env: $repo/events-processor/Dockerfile not found (wrong repo?)" >&2; return 1
  fi
  ref="${LAGO_EXPRESSION_REF:-$(sed -nE 's/.*git checkout (v[0-9][0-9.]*).*/\1/p' "$repo/events-processor/Dockerfile" | head -n1)}"
  if [ -z "$ref" ]; then
    echo "ep-env: could not read the lago-expression ref from events-processor/Dockerfile" >&2; return 1
  fi
  cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
  src="$cache/lago-expression-$ref"
  lib="$src/target/release"

  if [ ! -f "$lib/libexpression_go.so" ]; then
    command -v cargo >/dev/null 2>&1 || {
      echo "ep-env: cargo not found; install Rust (https://rustup.rs) and re-source" >&2; return 1; }
    if [ ! -d "$src/.git" ]; then
      mkdir -p "$cache" || return 1
      echo "ep-env: cloning getlago/lago-expression@$ref into $src" >&2
      git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" https://github.com/getlago/lago-expression "$src" || return 1
    fi
    echo "ep-env: building libexpression_go.so (cargo build --release, ~40 s first time)" >&2
    (cd "$src/expression-go" && cargo build --release --quiet) || return 1
  fi

  export LAGO_REPO="$repo" LAGO_SKILLS_CACHE="$cache" LAGO_EXPRESSION_REF="$ref" LAGO_EXPRESSION_LIB="$lib"
  export CGO_LDFLAGS="-L$lib"
  case ":${LD_LIBRARY_PATH:-}:" in
    *":$lib:"*) ;;
    *) export LD_LIBRARY_PATH="$lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
  esac
  export DATABASE_URL="${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}"
  # Never echo a password (change-control N11): mask user:PASS@ in the URL.
  echo "ep-env: lago-expression $ref -> $lib ; DATABASE_URL=$(printf '%s' "$DATABASE_URL" | sed -E 's#(://[^:/@]+:)[^@]*@#\1***@#')" >&2
}

if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "ep-env.sh must be sourced: source ${BASH_SOURCE[0]}" >&2
  exit 2
fi
_lago_ep_env
