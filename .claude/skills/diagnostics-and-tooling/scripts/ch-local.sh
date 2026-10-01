#!/usr/bin/env bash
# ch-local.sh — evaluate ClickHouse SQL locally with `clickhouse local` (no server,
# no Docker). Downloads the official static binary once into the cache dir.
#
# Usage:
#   ch-local.sh "<SQL>"            # run one query (default output: TabSeparated)
#   ch-local.sh -                  # read SQL from stdin
#   ch-local.sh --path             # print the binary path (download if needed), nothing else
#   ch-local.sh --version          # print the ClickHouse version that will be used
#   options (before the query):  --refresh  re-resolve the version and re-download
#
# Version: $CH_VERSION (e.g. 26.2.19.43) if set; otherwise the newest patch of
# <minor> ALREADY in the cache (no network), or, when none is cached or with
# --refresh, the newest `v<minor>.*-stable` tag of github.com/ClickHouse/ClickHouse
# (26.2.19.43 on 2026-10-01). <minor> comes from the clickhouse-server image in
# docker-compose.dev.yml (26.2 as of 2026-10-01). Production's ClickHouse
# version is unknown: treat results as "what this version does", not as
# production truth.
#
# Source: GitHub release asset clickhouse-common-static-<ver>-<arch>.tgz,
# verified against its .sha512 asset (packages.clickhouse.com is blocked in
# some sandboxes; github.com release assets were reachable on 2026-10-01).
# Cache: ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/clickhouse/<ver>/clickhouse
# (~211 MB download, ~724 MB on disk; the .tgz is deleted after extraction).
#
# The cache layout above is the ONE shared layout for every skill: callers get
# the binary with `ch-local.sh --path` instead of hardcoding a versioned path.
# Query mode reads stdin from /dev/null (an inherited open stdin pipe must never
# stall `clickhouse local`); `-` mode reads SQL from stdin until EOF.
#
# Exit codes: 0 ok; 1 usage; 2 download/verification/resolution failure
# (network blocked: say so, do not guess ClickHouse semantics); otherwise the
# exit code of clickhouse local (e.g. a SQL error).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/clickhouse"

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0" >&2; exit 1; }
die() { echo "ch-local: $2" >&2; exit "$1"; }

refresh=0 mode=query
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh) refresh=1; shift ;;
    --path) mode=path; shift ;;
    --version) mode=version; shift ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done
if [ "$mode" = query ] && [ $# -ne 1 ]; then usage; fi

case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die 2 "unsupported architecture $(uname -m)" ;;
esac

resolve_version() {
  if [ -n "${CH_VERSION:-}" ]; then echo "$CH_VERSION"; return; fi
  local minor newest
  minor="$(sed -nE 's#.*image: *clickhouse/clickhouse-server:([0-9]+\.[0-9]+).*#\1#p' "$repo/docker-compose.dev.yml" | head -n1)"
  [ -n "$minor" ] || die 2 "cannot read the clickhouse-server minor version from docker-compose.dev.yml"
  if [ "$refresh" = 0 ] && [ -d "$cache" ]; then
    # Reuse the newest already-downloaded patch of that minor (no network).
    newest="$(find "$cache" -mindepth 2 -maxdepth 2 -name clickhouse -path "$cache/$minor.*" 2>/dev/null \
      | sed -E "s#^$cache/([^/]+)/clickhouse\$#\1#" | sort -V | tail -n1)"
    if [ -n "$newest" ]; then echo "$newest"; return; fi
  fi
  newest="$(git ls-remote --tags https://github.com/ClickHouse/ClickHouse "v$minor.*-stable" 2>/dev/null \
    | sed -nE 's#.*refs/tags/v([0-9.]+)-stable$#\1#p' | sort -V | tail -n1)"
  [ -n "$newest" ] || die 2 "could not list v$minor.*-stable tags on github.com/ClickHouse/ClickHouse (network?)"
  echo "$newest"
}

ver="$(resolve_version)"
bin="$cache/$ver/clickhouse"
if [ "$mode" = version ]; then echo "$ver"; exit 0; fi

if [ ! -x "$bin" ] || [ "$refresh" = 1 ]; then
  command -v curl >/dev/null 2>&1 || die 2 "curl not found"
  asset="clickhouse-common-static-$ver-$arch.tgz"
  url="https://github.com/ClickHouse/ClickHouse/releases/download/v$ver-stable/$asset"
  dir="$cache/$ver"
  mkdir -p "$dir"
  echo "ch-local: downloading $asset (~211 MB) into $dir" >&2
  curl -fsSL -o "$dir/$asset" "$url" || die 2 "download failed: $url"
  curl -fsSL -o "$dir/$asset.sha512" "$url.sha512" || die 2 "checksum download failed: $url.sha512"
  (cd "$dir" && sha512sum -c --quiet "$asset.sha512") || die 2 "sha512 mismatch for $asset"
  member="$(tar -tzf "$dir/$asset" | grep -E '/usr/bin/clickhouse$' | head -n1)"
  [ -n "$member" ] || die 2 "no usr/bin/clickhouse inside $asset"
  tar -xzf "$dir/$asset" -C "$dir" --strip-components="$(awk -F/ '{print NF-1}' <<<"$member")" "$member"
  chmod +x "$bin"
  rm -f "$dir/$asset" "$dir/$asset.sha512"
  echo "ch-local: installed $bin" >&2
fi

if [ "$mode" = path ]; then echo "$bin"; exit 0; fi
if [ "$1" = "-" ]; then
  exec "$bin" local --multiquery
fi
exec "$bin" local --query "$1" </dev/null
