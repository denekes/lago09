#!/usr/bin/env bash
# hist.sh — rename-aware, read-only `git log` over the FULL history clone.
# The working clone is shallow; this always reads the bare clone from history-setup.sh.
# events-processor/ was called events_processor/ before d5bce86 (2025-03-21): --ep and
# --path events-processor/... include the old name automatically.
#
# Usage:
#   hist.sh [--ep|--infra|--all] [--path P]... [--since D] [--until D] [--humans]
#           [--no-bumps] [--grep RE] [--first-parent] [--reverse]
#           [--stat|--count|--authors] [-- <extra git log args>]
# Examples:
#   .claude/skills/failure-archaeology/scripts/hist.sh --ep --humans --count        # -> 79
#   .claude/skills/failure-archaeology/scripts/hist.sh --path events-processor/config/kafka/consumer.go --reverse
#   .claude/skills/failure-archaeology/scripts/hist.sh --infra --humans --no-bumps --grep 'fix|revert' --since 2025-01-01
#   .claude/skills/failure-archaeology/scripts/hist.sh --ep --authors
# Output (default): "<sha7> <YYYY-MM-DD> <author> | <subject>", newest first.
# Env: LAGO_HISTORY=<path> skips history-setup.sh.
# Exit: 0 ok (also when nothing matched); 2 usage error; 3 history clone unavailable.
set -euo pipefail
. "$(dirname "$0")/_lib.sh"

scope=all; paths=(); since=""; until=""; humans=0; nobumps=0; grep_re=""
firstparent=0; reverse=0; mode=list; extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ep) scope=ep; shift ;;
    --infra) scope=infra; shift ;;
    --all) scope=all; shift ;;
    --path) fa_need "$1" "${2:-}"; paths+=("$2"); shift 2 ;;
    --since) fa_need "$1" "${2:-}"; since="$2"; shift 2 ;;
    --until) fa_need "$1" "${2:-}"; until="$2"; shift 2 ;;
    --humans) humans=1; shift ;;
    --no-bumps) nobumps=1; shift ;;
    --grep) fa_need "$1" "${2:-}"; grep_re="$2"; shift 2 ;;
    --first-parent) firstparent=1; shift ;;
    --reverse) reverse=1; shift ;;
    --stat) mode=stat; shift ;;
    --count) mode=count; shift ;;
    --authors) mode=authors; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    --) shift; extra=("$@"); break ;;
    *) fa_die "unknown argument: $1 (see --help)" ;;
  esac
done

fa_init

specs=()
if [ ${#paths[@]} -gt 0 ]; then
  for p in "${paths[@]}"; do while IFS= read -r s; do specs+=("$s"); done < <(fa_expand_path "$p"); done
else
  while IFS= read -r s; do specs+=("$s"); done < <(fa_scope_specs "$scope")
fi

args=(log --no-color --date=short)
[ -n "$since" ] && args+=("--since=$since")
[ -n "$until" ] && args+=("--until=$until")
[ -n "$grep_re" ] && args+=(-i -E "--grep=$grep_re")
[ "$firstparent" = 1 ] && args+=(--first-parent)
[ "$reverse" = 1 ] && args+=(--reverse)

# One record per commit: sha, date, author, subject (tab-separated); shortstat follows in --stat mode.
fmt='%x1e%h%x09%ad%x09%an%x09%s'
if [ "$mode" = stat ]; then args+=(--shortstat); fi
args+=("--format=$fmt")
[ ${#extra[@]} -gt 0 ] && args+=("${extra[@]}")
args+=(--)
args+=("${specs[@]}")

G "${args[@]}" | awk -v humans="$humans" -v nobumps="$nobumps" -v bump="$FA_BUMP_RE" -v keep="$FA_KEEP_RE" -v mode="$mode" '
  BEGIN { RS = "\036"; FS = "\n"; n = 0 }
  NF == 0 || $1 == "" { next }
  {
    split($1, f, "\t")
    if (humans && f[3] ~ /dependabot/) next
    if (nobumps && tolower(f[4]) ~ bump && tolower(f[4]) !~ keep) next
    n++
    if (mode == "count") next
    if (mode == "authors") { a[f[3]]++; next }
    printf "%s %s %s | %s\n", f[1], f[2], f[3], f[4]
    if (mode == "stat") for (i = 2; i <= NF; i++) if ($i ~ /changed/) { sub(/^ +/, "", $i); print "    " $i }
  }
  END {
    if (mode == "count") print n
    if (mode == "authors") for (k in a) printf "%5d %s\n", a[k], k
  }' | { if [ "$mode" = authors ]; then sort -rn; else cat; fi; }
