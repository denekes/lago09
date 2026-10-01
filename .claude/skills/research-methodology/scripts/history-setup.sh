#!/usr/bin/env bash
# history-setup.sh — ensure a FULL-history, blob-less bare clone of this repo exists
# and print its path. Needed because cloud/CI checkouts are usually shallow.
#
# Usage:
#   H=$(.claude/skills/research-methodology/scripts/history-setup.sh)            # create or reuse
#   H=$(.claude/skills/research-methodology/scripts/history-setup.sh --refresh)  # also fetch new commits
#   .../history-setup.sh --remote https://github.com/getlago/lago                # pick the source
#   git -C "$H" log --oneline -- events-processor events_processor
#
# Default remote: `git remote get-url origin` of the current checkout, else getlago/lago.
# Blobs are fetched lazily, so `git -C "$H" show <sha>` needs network the first time.
# Writes only under ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/lago-history.git
set -euo pipefail
cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
remote=""; refresh=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remote)  remote="${2:?--remote needs a URL}"; shift 2;;
    --refresh) refresh=1; shift;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) echo "history-setup: unknown argument: $1" >&2; exit 2;;
  esac
done
if [ -z "$remote" ]; then
  remote="$(git remote get-url origin 2>/dev/null || echo https://github.com/getlago/lago)"
fi
dest="$cache/lago-history.git"
if [ ! -d "$dest" ]; then
  mkdir -p "$cache"
  echo "history-setup: cloning $remote (bare, blob-less) into $dest" >&2
  git clone --quiet --bare --filter=blob:none "$remote" "$dest"
elif [ "$refresh" = 1 ]; then
  git -C "$dest" fetch --quiet --filter=blob:none origin '+refs/heads/*:refs/heads/*'
fi
echo "$dest"
