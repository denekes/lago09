#!/usr/bin/env bash
# pinned-checkout.sh — read-only, shallow checkout of a submodule (lago-api or lago-front)
# at EXACTLY the commit this superproject pins, and print its path.
# Use it when api/ or front/ are empty (the usual case in agent sessions).
#
# Usage:
#   API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)
#   FRONT=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh front)
#   .../pinned-checkout.sh api <sha>        # any other lago-api commit
#
# The pin is read with `git ls-tree HEAD <api|front>` (the gitlink), not from the
# (possibly empty or drifted) working-tree directory.
# Writes only under ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/lago-<name>@<sha12>
set -euo pipefail
name="${1:-}"
case "$name" in
  api)   url=https://github.com/getlago/lago-api ;;
  front) url=https://github.com/getlago/lago-front ;;
  -h|--help|"") sed -n '2,14p' "$0"; exit 0 ;;
  *) echo "pinned-checkout: first argument must be api or front" >&2; exit 2 ;;
esac
repo="$(git rev-parse --show-toplevel)"
sha="${2:-$(git -C "$repo" ls-tree HEAD "$name" | awk '{print $3}')}"
[ -n "$sha" ] || { echo "pinned-checkout: no gitlink for $name at HEAD" >&2; exit 1; }
cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
dest="$cache/lago-$name@${sha:0:12}"
if [ ! -d "$dest/.git" ]; then
  mkdir -p "$dest"
  git -C "$dest" init -q
  git -C "$dest" remote add origin "$url"
  echo "pinned-checkout: fetching $url @ $sha (depth 1) into $dest" >&2
  GIT_LFS_SKIP_SMUDGE=1 git -C "$dest" fetch -q --depth 1 origin "$sha"
  git -C "$dest" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
echo "$dest"
