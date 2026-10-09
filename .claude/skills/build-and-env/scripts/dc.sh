#!/usr/bin/env bash
# dc.sh — alias-free stand-in for the `lago` shell alias of docs/dev_environment.md:
#     alias lago="docker compose -f $LAGO_PATH/docker-compose.dev.yml"
# Agent and CI shells never load that alias, and a `lago` binary on PATH is usually
# getlago/lago-cli (no `exec`/`up`). Use this instead, from any directory:
#
# Usage:
#   dc.sh config --services                         # works without a Docker daemon
#   dc.sh --profile '*' config --services           # include profile-gated services
#   dc.sh up -d --wait db redis traefik clickhouse webhook   # needs a daemon
#   dc.sh exec events-processor go test ./...       # = `lago exec events-processor go test ./...`
#
# Compose file: $LAGO_PATH/docker-compose.dev.yml if LAGO_PATH is set (same as the
# alias), else <repo containing this script>/docker-compose.dev.yml. Relative paths
# inside the file resolve against its own directory, so the cwd does not matter.
# Exit: docker compose's exit code; 2 = docker CLI or compose file missing.
# When compose fails and no daemon is reachable, prints a one-line hint on stderr.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
own="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || true)"
root="${LAGO_PATH:-$own}"
if [ -n "${LAGO_PATH:-}" ] && [ -n "$own" ] && [ "$(cd "$LAGO_PATH" 2>/dev/null && pwd -P)" != "$(cd "$own" && pwd -P)" ]; then
  echo "dc.sh: note: LAGO_PATH=$LAGO_PATH differs from this checkout ($own); using LAGO_PATH" >&2
fi
file="$root/docker-compose.dev.yml"
[ -f "$file" ] || { echo "dc.sh: $file not found (set LAGO_PATH to the lago repo root)" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "dc.sh: docker CLI not installed" >&2; exit 2; }

set +e
docker compose -f "$file" "$@"
rc=$?
set -e
if [ "$rc" -ne 0 ] && ! docker info >/dev/null 2>&1; then
  echo "dc.sh: note: no Docker daemon is reachable; only client-side subcommands such as 'config' can work here" >&2
fi
exit "$rc"
