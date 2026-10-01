#!/usr/bin/env bash
# incidents.sh — read-only sweeps of the FULL history for failure signals.
# Uses the history clone from history-setup.sh (the working clone is shallow).
#
# Usage:
#   incidents.sh [--ep|--infra|--all] [--since D] [--until D] [MODE]
# MODES (pick one; default --list):
#   --list            incident-like commits (dependabot and release bumps dropped), tagged
#                     REVERT | HOTFIX | TICKET | REMOVAL | FIX | SIGNAL (keyword only in the body)
#   --reverts         only revert / hotfix / rollback commits
#   --tickets         ING-/INF- ticket ids found anywhere in commit messages, with their commits
#   --followups [N]   "fix-after-fix": fix commits landing within N days (default 14) of an
#                     earlier non-bot commit that touched the same file (api/front gitlinks ignored)
#   --removed         files deleted (renames excluded), one line per commit, bulk noise collapsed
#   --todos           TODO/FIXME/HACK lines in the working tree (first-party paths), with the oldest commit
#                     that added the text (searched in the file's top-level dir) and its age in days
# Examples:
#   .claude/skills/failure-archaeology/scripts/incidents.sh --reverts
#   .claude/skills/failure-archaeology/scripts/incidents.sh --ep --followups
#   .claude/skills/failure-archaeology/scripts/incidents.sh --tickets
# Env: LAGO_HISTORY=<path> skips history-setup.sh.
# Exit: 0 ok (also when nothing matched); 2 usage error; 3 history clone unavailable.
set -euo pipefail
. "$(dirname "$0")/_lib.sh"

scope=all; since=""; until=""; mode=list; days=14
while [ $# -gt 0 ]; do
  case "$1" in
    --ep) scope=ep; shift ;;
    --infra) scope=infra; shift ;;
    --all) scope=all; shift ;;
    --since) fa_need "$1" "${2:-}"; since="$2"; shift 2 ;;
    --until) fa_need "$1" "${2:-}"; until="$2"; shift 2 ;;
    --list|--reverts|--tickets|--removed|--todos) mode="${1#--}"; shift ;;
    --followups)
      mode=followups; shift
      if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then days="$1"; shift; fi ;;
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) fa_die "unknown argument: $1 (see --help)" ;;
  esac
done

fa_init
specs=(); while IFS= read -r s; do specs+=("$s"); done < <(fa_scope_specs "$scope")
range=(); [ -n "$since" ] && range+=("--since=$since"); [ -n "$until" ] && range+=("--until=$until")
FIX_RE='fix|hotfix|revert|(^|[^a-z])bug|broken|typo|repair'

case "$mode" in
list|reverts)
  G log --no-color --date=short ${range[@]+"${range[@]}"} --format='%x1e%h%x09%ad%x09%an%x09%s%x09%b' -- "${specs[@]}" |
  awk -v mode="$mode" -v bump="$FA_BUMP_RE" -v keep="$FA_KEEP_RE" '
    BEGIN { RS = "\036" }
    NF == 0 { next }
    {
      split($0, f, "\t"); sha = f[1]; d = f[2]; an = f[3]; s = f[4]
      body = substr($0, length(f[1] f[2] f[3] f[4]) + 5)
      ls = tolower(s); lb = tolower(body)
      if (an ~ /dependabot/) next
      if (ls ~ bump && ls !~ keep) next
      tag = ""
      if (ls ~ /revert|rollback/) tag = "REVERT"
      else if (ls ~ /hotfix/) tag = "HOTFIX"
      else if (mode == "reverts") next
      else if ((ls lb) ~ /(ing|inf)-[0-9]+/) tag = "TICKET"
      else if (ls ~ /fix|(^|[^a-z])bug|typo|broken|missing|wrong|flaky|infinit/) tag = "FIX"
      else if (ls ~ /remove|delete|drop /) tag = "REMOVAL"
      else if (lb ~ /segfault|sqlstate|429 too many|unrecoverable|panic|infinite loop/) tag = "SIGNAL"
      else next
      printf "%-7s %s %s %s | %s\n", tag, sha, d, an, s
    }'
  ;;
tickets)
  G log --no-color --date=short ${range[@]+"${range[@]}"} -E --grep='(ING|INF)-[0-9]+' --format='%x1e%h%x09%ad%x09%s%x09%B' -- "${specs[@]}" |
  awk 'BEGIN { RS = "\036" }
    NF == 0 { next }
    {
      split($0, f, "\t"); txt = $0; seen = ""
      while (match(txt, /(ING|INF)-[0-9]+/)) {
        id = substr(txt, RSTART, RLENGTH); txt = substr(txt, RSTART + RLENGTH)
        if (index(seen, "|" id "|")) continue
        seen = seen "|" id "|"
        printf "%-8s %s %s | %s\n", id, f[1], f[2], f[3]
      }
    }' | sort -k1,1 -k3,3
  ;;
followups)
  G log --no-color --reverse --no-merges --date=short ${range[@]+"${range[@]}"} --format='%x1e%h%x09%at%x09%ad%x09%an%x09%s' --name-only -- "${specs[@]}" |
  awk -v days="$days" -v fixre="$FIX_RE" -v bump="$FA_BUMP_RE" -v keep="$FA_KEEP_RE" '
    BEGIN { RS = "\036"; FS = "\n"; SEP = "\034"; win = days * 86400 }
    NF == 0 { next }
    {
      split($1, f, "\t"); sha = f[1]; at = f[2] + 0; d = f[3]; an = f[4]; s = f[5]
      if (an ~ /dependabot/) next
      isfix = (tolower(s) ~ fixre)
      best_at = -1; best = ""; bestfile = ""; nprior = 0
      for (i = 2; i <= NF; i++) {
        file = $i; if (file == "" || file == "api" || file == "front") continue
        if (isfix && (file in hist)) {
          n = split(hist[file], e, SEP)
          for (j = 1; j <= n; j++) {
            split(e[j], p, "\t")   # p: at, sha, date, subject
            dt = at - p[1]
            if (dt < 0 || dt > win || p[2] == sha) continue
            if (file == "docker-compose.yml" && tolower(p[4]) ~ bump && tolower(p[4]) !~ keep) continue
            nprior++
            if (p[1] > best_at) { best_at = p[1]; best = p[2] " " p[3] " " p[4]; bestfile = file; bestdt = dt }
          }
        }
      }
      if (best != "")
        printf "%s %s %s\n    <- %s  (%.1f d, %d prior touch(es); e.g. %s)\n", sha, d, s, best, bestdt / 86400, nprior, bestfile
      for (i = 2; i <= NF; i++) {
        file = $i; if (file == "") continue
        entry = at "\t" sha "\t" d "\t" s
        hist[file] = (file in hist) ? hist[file] SEP entry : entry
        # keep the per-file list short: drop entries older than the window
        n = split(hist[file], e, SEP); keep = ""
        for (j = 1; j <= n; j++) { split(e[j], p, "\t"); if (at - p[1] <= win) keep = (keep == "" ? e[j] : keep SEP e[j]) }
        hist[file] = keep
      }
    }'
  ;;
removed)
  G log --no-color -M --diff-filter=D --date=short ${range[@]+"${range[@]}"} --format='%x1e%h%x09%ad%x09%s' --name-only -- "${specs[@]}" |
  awk 'BEGIN { RS = "\036"; FS = "\n" }
    NF == 0 { next }
    {
      split($1, f, "\t"); n = 0; noise = 0; list = ""
      for (i = 2; i <= NF; i++) {
        if ($i == "") continue
        if ($i ~ /Zone\.Identifier$|\.jar$/) { noise++; continue }
        n++; if (n <= 5) list = list " " $i
      }
      more = (n > 5) ? sprintf(" [+%d more]", n - 5) : ""
      nz = (noise > 0) ? sprintf(" [+%d jar/Zone.Identifier]", noise) : ""
      printf "%s %s | %s ::%s%s%s\n", f[1], f[2], f[3], list, more, nz
    }'
  ;;
todos)
  root="$(fa_repo_root)"; now="$(date +%s)"
  todo_paths=(events-processor deploy docker scripts .github docs extra connectors traefik examples
              docker-compose.yml docker-compose.dev.yml .env.development.default)
  existing=(); for p in "${todo_paths[@]}"; do [ -e "$root/$p" ] && existing+=("$p"); done
  ( cd "$root" && grep -rnE 'TODO|FIXME|HACK' "${existing[@]}" 2>/dev/null || true ) |
  while IFS= read -r hit; do
    file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"
    text="$(printf '%s' "$text" | sed -E 's/^[[:space:]]+//')"
    # search the file's top-level directory (rename-aware) so moved files keep their true origin
    top="${file%%/*}"; [ "$top" = "$file" ] && top="$file"
    specs_f=(); while IFS= read -r s; do specs_f+=("$s"); done < <(fa_expand_path "$top")
    intro="$(G log --no-color --reverse --format='%h %ad %at' --date=short -S"$text" -- "${specs_f[@]}" 2>/dev/null || true)"
    intro="${intro%%$'\n'*}"   # oldest commit only (no `| head`: SIGPIPE + pipefail would abort)
    if [ -n "$intro" ]; then
      set -- $intro; age=$(( (now - $3) / 86400 ))
      printf '%s:%s  added %s %s (%d days)  %s\n' "$file" "$line" "$1" "$2" "$age" "$text"
    else
      printf '%s:%s  added (not found in history clone)  %s\n' "$file" "$line" "$text"
    fi
  done
  ;;
esac
