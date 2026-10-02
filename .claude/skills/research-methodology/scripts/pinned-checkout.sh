#!/usr/bin/env bash
# pinned-checkout.sh — read-only, shallow checkout of a submodule (lago-api or lago-front)
# at EXACTLY the commit this superproject pins, and print its path.
# Use it when api/ or front/ are empty (the usual case in agent sessions).
#
# Usage:
#   API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)
#   FRONT=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh front)
#   .../pinned-checkout.sh api <40-hex-sha>   # any other lago-api commit (full sha only)
#
# The pin is read with `git ls-tree HEAD <api|front>` (the gitlink) of the repo this script
# lives in (if the script is not inside a git repo: of the current checkout), not from the
# (possibly empty or drifted) working-tree directory.
# Writes only under ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/lago-<name>@<sha12>
# Exit: 0 path printed; 1 no gitlink / fetch failed; 2 usage error (bad name or short sha).
set -euo pipefail
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"   # fail, never hang on a credential prompt
name="${1:-}"
case "$name" in
  api)   url=https://github.com/getlago/lago-api ;;
  front) url=https://github.com/getlago/lago-front ;;
  -h|--help|"") sed -n '2,15p' "$0"; exit 0 ;;
  *) echo "pinned-checkout: first argument must be api or front" >&2; exit 2 ;;
esac
if [ $# -ge 2 ]; then
  sha="$2"   # explicit: an EMPTY value is an error, never a silent fallback to the pin
  [ -n "$sha" ] || { echo "pinned-checkout: empty sha argument (unset variable?)" >&2; exit 2; }
else
  repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel)"
  sha="$(git -C "$repo" ls-tree HEAD "$name" | awk '{print $3}')"
fi
[ -n "$sha" ] || { echo "pinned-checkout: no gitlink for $name at HEAD" >&2; exit 1; }
# GitHub only serves fetch-by-sha for FULL object names; a short sha fails remotely.
if ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "pinned-checkout: need a full 40-hex commit sha, got '$sha'" >&2
  echo "  resolve tags with: git ls-remote --tags $url  (or tag-map.sh)" >&2
  exit 2
fi
cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
dest="$cache/lago-$name@${sha:0:12}"
# A cache dir is valid only if its HEAD is exactly the requested commit.
# (Bug fixed 2026-10-01: a failed fetch used to leave an empty dir that later
#  calls returned with exit 0, so greps over it silently found nothing.)
if [ -d "$dest" ] && [ "$(git -C "$dest" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$sha" ]; then
  echo "pinned-checkout: discarding incomplete cache dir $dest" >&2
  rm -rf -- "$dest"
fi
if [ ! -d "$dest" ]; then
  mkdir -p "$cache"
  tmp="$(mktemp -d "$cache/.lago-$name.XXXXXX")"
  trap 'rm -rf -- "$tmp"' EXIT
  git -C "$tmp" init -q
  git -C "$tmp" remote add origin "$url"
  echo "pinned-checkout: fetching $url @ $sha (depth 1) into $dest" >&2
  if ! GIT_LFS_SKIP_SMUDGE=1 git -C "$tmp" fetch -q --depth 1 origin "$sha"; then
    echo "pinned-checkout: fetch failed (sha not on the remote, or no network)" >&2
    exit 1
  fi
  git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD
  # Parallel callers: whoever moves first wins; a loser keeps the winner's dir.
  if ! mv -T -- "$tmp" "$dest" 2>/dev/null; then
    [ -d "$dest" ] || mv -- "$tmp" "$dest"   # mv without -T (BSD/macOS)
  fi
fi
echo "$dest"
