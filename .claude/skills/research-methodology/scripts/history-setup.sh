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
# Default remote: `git remote get-url origin` of the repo this script lives in (so a call
# from another repository's checkout never clones that repository); if the script is not
# inside a git repo, of the current checkout; else getlago/lago.
# --remote only applies when the clone is CREATED; an existing clone keeps its origin
# (a warning is printed on mismatch; use another LAGO_SKILLS_CACHE for a second source).
# Blobs are fetched lazily, so `git -C "$H" show <sha>` needs network the first time.
# Writes only under ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/lago-history.git
# Exit: 0 path printed; 2 usage error; git's exit code if clone/fetch fails.
set -euo pipefail
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"   # fail, never hang on a credential prompt
cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
remote=""; refresh=0; explicit_remote=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remote)  remote="${2:?--remote needs a URL}"; explicit_remote=1; shift 2;;
    --refresh) refresh=1; shift;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "history-setup: unknown argument: $1" >&2; exit 2;;
  esac
done
if [ -z "$remote" ]; then
  remote="$(git -C "$(dirname "$0")" remote get-url origin 2>/dev/null \
            || git remote get-url origin 2>/dev/null \
            || echo https://github.com/getlago/lago)"
fi
dest="$cache/lago-history.git"
if [ ! -d "$dest" ]; then
  mkdir -p "$cache"
  echo "history-setup: cloning $remote (bare, blob-less) into $dest" >&2
  git clone --quiet --bare --filter=blob:none "$remote" "$dest"
else
  have="$(git -C "$dest" config --get remote.origin.url || true)"
  if [ "$explicit_remote" = 1 ] && [ "$have" != "$remote" ]; then
    echo "history-setup: WARNING existing clone is from $have; --remote $remote ignored" >&2
  fi
  if [ "$refresh" = 1 ]; then
    git -C "$dest" fetch --quiet --filter=blob:none origin '+refs/heads/*:refs/heads/*'
  fi
fi
# Every lazy blob fetch would otherwise trigger auto-maintenance ("Auto packing the
# repository in background ..." on stderr, repeated repacks). Idempotent.
if [ "$(git -C "$dest" config --get maintenance.auto || true)" != "false" ]; then
  git -C "$dest" config maintenance.auto false
  git -C "$dest" config gc.auto 0
fi
echo "$dest"
