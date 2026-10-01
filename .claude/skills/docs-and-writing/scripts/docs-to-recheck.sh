#!/usr/bin/env bash
# docs-to-recheck.sh — apply the doc maintenance map (../reference/maintenance.md, table "Map") to a
# set of changed files and print which docs of record and stale-claim entries to re-check.
# The map table is the single source: this script parses it, so edit the table, not the script.
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/docs-and-writing/scripts/docs-to-recheck.sh                  # working tree + index vs HEAD (incl. untracked)
#   .../docs-to-recheck.sh --staged                                              # index vs HEAD
#   .../docs-to-recheck.sh --range origin/main..HEAD                             # a commit range
#   .../docs-to-recheck.sh -C "$H" --range 2fd8e8b^..2fd8e8b                     # replay on the history clone
#   .../docs-to-recheck.sh -- events-processor/main.go docker-compose.dev.yml    # explicit repo-relative paths
# Output: one block per matching map row:
#   RECHECK <docs>
#     look for: <what>   entries: <SC-IDs>
#     because:  <changed files that matched>
# then "SUMMARY docs-to-recheck: changed=N matched-rows=M unmapped=K", and the unmapped files
# (changed files that match no row; usually fine, e.g. tests).
# Exit: 0 (informational); 2 = usage error, map not found, or git error.
# Read-only.
set -euo pipefail
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
map="$here/../reference/maintenance.md"
mode=worktree range="" gitdir="" paths=()
while [ $# -gt 0 ]; do
  case "$1" in
    --staged) mode=staged; shift ;;
    --range) mode=range; range="${2:?--range needs A..B}"; shift 2 ;;
    -C) gitdir="${2:?-C needs a directory}"; shift 2 ;;
    --) shift; mode=paths; paths=("$@"); break ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "docs-to-recheck: unknown argument: $1 (see -h)" >&2; exit 2 ;;
  esac
done
[ -f "$map" ] || { echo "docs-to-recheck: map not found: $map" >&2; exit 2; }
# Without -C, run git from the top level so that untracked paths (ls-files is cwd-relative)
# come out repo-relative like the diff paths, whatever the caller's cwd.
if [ -z "$gitdir" ] && [ "$mode" != paths ]; then
  gitdir="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "docs-to-recheck: not inside a git work tree (use -C)" >&2; exit 2; }
fi
G=(git); [ -n "$gitdir" ] && G=(git -C "$gitdir")

case "$mode" in
  paths)    changed="$(printf '%s\n' "${paths[@]}")" ;;
  staged)   changed="$("${G[@]}" diff --cached --name-only)" || exit 2 ;;
  range)    changed="$("${G[@]}" diff --name-only "$range")" || exit 2 ;;
  worktree) changed="$({ "${G[@]}" diff --name-only HEAD; "${G[@]}" ls-files --others --exclude-standard; } | sort -u)" || exit 2 ;;
esac
changed="$(printf '%s\n' "$changed" | sed '/^$/d' | sort -u)"
nchanged="$(printf '%s\n' "$changed" | sed '/^$/d' | wc -l | tr -d ' ')"

# Rows of the "## Map" table, minus header/separator: | globs | docs | look for | entries |
rows="$(awk '/^## Map/{f=1;next} /^## /{f=0} f && /^\| `/' "$map")"
[ -n "$rows" ] || { echo "docs-to-recheck: no map rows parsed from $map" >&2; exit 2; }

matched_rows=0 mapped=""
while IFS= read -r row; do
  globs="$(printf '%s' "$row" | awk -F' \\| ' '{sub(/^\| /,"",$1); print $1}')"
  docs="$(printf '%s' "$row" | awk -F' \\| ' '{print $2}')"
  look="$(printf '%s' "$row" | awk -F' \\| ' '{print $3}')"
  entries="$(printf '%s' "$row" | awk -F' \\| ' '{sub(/ \|$/,"",$4); print $4}')"
  hits=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    IFS=', ' read -r -a gl <<<"$(printf '%s' "$globs" | tr -d '`')"   # read -a: no pathname expansion
    for g in "${gl[@]}"; do
      # shellcheck disable=SC2053  # $g is a glob on purpose
      if [[ "$f" == $g ]]; then hits="$hits $f"; mapped="$mapped"$'\n'"$f"; break; fi
    done
  done <<<"$changed"
  if [ -n "$hits" ]; then
    matched_rows=$((matched_rows+1))
    read -r -a hv <<<"$hits"
    because="${hv[*]:0:5}"; [ "${#hv[@]}" -le 5 ] || because="$because (+$(( ${#hv[@]} - 5 )) more)"
    printf 'RECHECK %s\n  look for: %s   entries: %s\n  because: %s\n' "$docs" "$look" "$entries" "$because"
  fi
done <<<"$rows"

unmapped="$(comm -23 <(printf '%s\n' "$changed" | sed '/^$/d' | sort -u) <(printf '%s\n' "$mapped" | sed '/^$/d' | sort -u))"
nunmapped="$(printf '%s\n' "$unmapped" | sed '/^$/d' | wc -l | tr -d ' ')"
echo "SUMMARY docs-to-recheck: changed=$nchanged matched-rows=$matched_rows unmapped=$nunmapped"
[ "$nunmapped" -eq 0 ] || printf '%s\n' "$unmapped" | sed '/^$/d; s/^/  unmapped: /'
exit 0
