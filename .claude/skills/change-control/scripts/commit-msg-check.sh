#!/usr/bin/env bash
# commit-msg-check.sh — check commit subjects against the conventions this repo operates
# under (change-control "Commit and PR conventions"; OPEN DECISION OD-7 defaults).
#
# Usage:
#   commit-msg-check.sh <file>                    # a commit message file (git commit-msg hook form;
#                                                 #   git-generated "Merge ..." subjects are skipped)
#   commit-msg-check.sh -m "<subject>"            # one subject line
#   commit-msg-check.sh --range <A>..<B>          # every non-merge commit reachable from B, not from A
#   commit-msg-check.sh --since <date> [--rev R]  # every non-merge commit since <date> (replay)
# Options:
#   -C <dir>          run git against another checkout or the bare history clone
#   --include-merges  also check merge commits ("Merge pull request #N ..." is skipped by default)
#   --exclude-bots    skip authors ending in [bot] (dependabot)
#   --max N / --pref N   hard / preferred subject length (default 72 / 50, OD-7)
#   --report          print the summary only and always exit 0 (history measurement)
#   -q                print FAIL lines only (no WARN lines)
#
# Rules (subject = first line, as it will land on main; GitHub appends " (#NNN)" on squash):
#   M1 FAIL  longer than --max (72)
#   M2 WARN  longer than --pref (50)
#   M3 FAIL  not Conventional Commits: [optional "[ING-n] " / "[INF-n] "]type(scope)!: description
#   M4 FAIL  type outside: feat fix docs style refactor test chore perf ci build revert misc
#   M5 WARN  description ends with "."
#   M6 FAIL  WIP / fixup! / squash! / amend! subject (must not land on main)
#   M7 WARN  (file mode) second line not blank
# Exit codes: 0 = no FAIL (or --report), 1 = at least one FAIL, 2 = usage or git error
# (including an unknown revision in --range/--rev).
set -euo pipefail
if locale -a 2>/dev/null | grep -qix 'c.utf-\{0,1\}8'; then export LC_ALL=C.UTF-8; fi

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

TYPES="feat fix docs style refactor test chore perf ci build revert misc"
max=72 pref=50 mode="" arg="" rev="HEAD" dir="" merges=0 nobots=0 report=0 quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    -m) mode=subject; arg="${2?-m needs a subject}"; shift 2 ;;
    --range) mode=range; arg="${2:?--range needs A..B}"; shift 2 ;;
    --since) mode=since; arg="${2:?--since needs a date}"; shift 2 ;;
    --rev) rev="${2:?--rev needs a revision}"; shift 2 ;;
    -C) dir="${2:?-C needs a directory}"; shift 2 ;;
    --include-merges) merges=1; shift ;;
    --exclude-bots) nobots=1; shift ;;
    --max) max="${2:?}"; shift 2 ;;
    --pref) pref="${2:?}"; shift 2 ;;
    --report) report=1; shift ;;
    -q) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "commit-msg-check: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) [ -n "$mode" ] && { echo "commit-msg-check: unexpected argument $1" >&2; exit 2; }
       mode=file; arg="$1"; shift ;;
  esac
done
[ -z "$mode" ] && { usage >&2; exit 2; }

n=0 nfail=0 nwarn=0 n_max=0 n_pref=0 n_nonconv=0 n_type=0 n_wip=0
declare -A bytype=()

# check_subject <label> <subject> [<second line>] : prints findings, updates counters
check_subject() {
  local label="$1" s="$2" second="${3-}" f=0 w=0 out="" len type re
  n=$((n+1))
  len=${#s}
  if [ "$len" -gt "$max" ]; then out+="FAIL M1 ${len}>${max} chars"$'\n'; f=1; n_max=$((n_max+1)); fi
  if [ "$len" -gt "$pref" ]; then n_pref=$((n_pref+1)); [ "$len" -le "$max" ] && { out+="WARN M2 ${len}>${pref} chars (preferred)"$'\n'; w=1; }; fi
  re='^(\[(ING|INF)-[0-9]+\] )?([a-z]+)(\([^)]+\))?!?: [^ ].*$'
  if [[ "$s" =~ $re ]]; then
    type="${BASH_REMATCH[3]}"
    bytype[$type]=$(( ${bytype[$type]:-0} + 1 ))
    if [[ " $TYPES " != *" $type "* ]]; then out+="FAIL M4 type '$type' not in: $TYPES"$'\n'; f=1; n_type=$((n_type+1)); fi
    case "$s" in *.) out+="WARN M5 description ends with '.'"$'\n'; w=1 ;; esac
  else
    out+="FAIL M3 not Conventional Commits: '[ING-n] '?type(scope)?: description"$'\n'; f=1; n_nonconv=$((n_nonconv+1))
    bytype["<non-conventional>"]=$(( ${bytype["<non-conventional>"]:-0} + 1 ))
  fi
  if [[ "$s" =~ ^(fixup!|squash!|amend!)|(^|[^A-Za-z])WIP([^A-Za-z]|$) ]]; then out+="FAIL M6 WIP/fixup/squash subject must not land on main"$'\n'; f=1; n_wip=$((n_wip+1)); fi
  if [ -n "$second" ]; then out+="WARN M7 line 2 must be blank"$'\n'; w=1; fi
  [ "$f" = 1 ] && nfail=$((nfail+1))
  [ "$w" = 1 ] && [ "$f" = 0 ] && nwarn=$((nwarn+1))
  if [ "$report" = 0 ] && [ -n "$out" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      [ "$quiet" = 1 ] && [ "${line%% *}" = WARN ] && continue
      printf '%s %s | %s\n' "$line" "$label" "$s"
    done <<< "$out"
  fi
  return 0
}

G=(git -c gc.auto=0)
[ -n "$dir" ] && G+=(-C "$dir")

case "$mode" in
  subject) check_subject "(subject)" "$arg" ;;
  file)
    [ -r "$arg" ] || { echo "commit-msg-check: cannot read $arg" >&2; exit 2; }
    # drop git comment lines, take the first two remaining lines
    mapfile -t lines < <(grep -v '^#' "$arg" || true)
    # git-generated merge subjects are skipped, as in --range/--since mode
    if [[ "${lines[0]-}" =~ ^Merge\ (pull\ request|branch|remote-tracking) ]]; then
      echo "SUMMARY commit-msg-check: 0 FAIL, 0 WARN (git merge subject skipped)"; exit 0
    fi
    check_subject "$(basename "$arg")" "${lines[0]-}" "${lines[1]-}" ;;
  range|since)
    "${G[@]}" rev-parse --git-dir >/dev/null 2>&1 || { echo "commit-msg-check: not a git repository: ${dir:-$PWD}" >&2; exit 2; }
    logargs=(--format='%h%x09%an%x09%s')
    [ "$merges" = 0 ] && logargs+=(--no-merges)
    if [ "$mode" = range ]; then logargs+=("$arg"); else logargs+=(--since="$arg" "$rev"); fi
    nbots=0
    # Capture first so a bad revision is a usage error (exit 2), not a silent "0 subjects" pass.
    what="--range $arg"; [ "$mode" = since ] && what="--rev $rev"
    logout="$("${G[@]}" log "${logargs[@]}")" || { echo "commit-msg-check: git log failed for $what (unknown revision?)" >&2; exit 2; }
    while IFS=$'\t' read -r h an s; do
      [ -z "$h" ] && continue
      if [[ "$an" == *"[bot]" ]]; then
        [ "$nobots" = 1 ] && continue
        nbots=$((nbots+1))
      fi
      [[ "$s" =~ ^Merge\ (pull\ request|branch|remote-tracking) ]] && continue
      check_subject "$h" "$s"
    done <<< "$logout"
    ;;
esac

if [ "$mode" = range ] || [ "$mode" = since ] || [ "$report" = 1 ]; then
  echo "SUMMARY commit-msg-check: $n subjects; >$max: $n_max; >$pref: $n_pref; non-conventional: $n_nonconv; unknown type: $n_type; WIP/fixup: $n_wip; FAIL subjects: $nfail; WARN-only subjects: $nwarn${nbots:+; bot-authored included: $nbots}"
  printf 'TYPES '; for t in "${!bytype[@]}"; do printf '%s=%s\n' "$t" "${bytype[$t]}"; done | sort -t= -k2,2nr | tr '\n' ' '; echo
else
  echo "SUMMARY commit-msg-check: $nfail FAIL, $nwarn WARN"
fi
[ "$report" = 1 ] && exit 0
[ "$nfail" -eq 0 ]
