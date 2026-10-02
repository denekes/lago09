#!/usr/bin/env bash
# explain-error.sh - map a known error string / log line of the Lago umbrella repo
# (events-processor startup and runtime, DLQ codes, build/test, dev stack, CI, release)
# to its debugging-playbook entry: meaning, ranked causes, confirm command, fix or owner.
#
# Usage:
#   explain-error.sh "<message or log line>"   explain one message (multi-line text is fine)
#   explain-error.sh -                         read lines from stdin; print each matched entry once,
#                                              with how many lines matched it
#   explain-error.sh --brief -                 same, one line per entry: <id> TAB <lines> TAB <title>
#   explain-error.sh --list                    list every entry: <id> TAB <area> TAB <title>
#   explain-error.sh --id <id>                 print one entry
#   explain-error.sh --self-test               validate patterns.txt: keys, unique ids, regexes,
#                                              and every example matches its own entry
#   explain-error.sh --help
#
# Data: patterns.txt next to this script (format documented at its top). Matching is
# case-sensitive bash ERE ([[ text =~ re ]]); every matching entry is printed.
#
# Exit codes: 0 at least one entry matched (or --list / --id / --self-test succeeded)
#             1 nothing matched (unknown string) / --id not found / --self-test failed
#             2 usage error, or patterns.txt unreadable
# Read-only: reads patterns.txt and stdin/arguments; writes only to stdout/stderr. Bash >= 4.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
db="${EXPLAIN_PATTERNS:-$here/patterns.txt}"
skill_rel=".claude/skills/debugging-playbook"

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

[ -r "$db" ] || { echo "explain-error: cannot read $db" >&2; exit 2; }

# ---- load patterns.txt into parallel arrays -------------------------------------------
declare -a E_ID E_AREA E_TITLE E_CAUSE E_CONFIRM E_FIX E_SEE E_EVID E_EX E_NMATCH
declare -a M_RE M_ENTRY          # flat list of regexes and the entry index each belongs to
declare -A ID_INDEX
n=0 cur=-1 load_err=0

start_entry() { cur=$n; n=$((n + 1)); E_NMATCH[cur]=0; E_EX[cur]=""; }

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in
    '#'*) continue ;;
    '') cur=-1; continue ;;
  esac
  key="${line%%: *}"
  val="${line#*: }"
  if [ "$key" = "$line" ]; then
    echo "explain-error: patterns.txt: unparsable line: $line" >&2; load_err=1; continue
  fi
  if [ "$key" = "id" ]; then
    start_entry
    E_ID[cur]="$val"
    if [ -n "${ID_INDEX[$val]:-}" ]; then
      echo "explain-error: patterns.txt: duplicate id $val" >&2; load_err=1
    fi
    ID_INDEX[$val]=$cur
    continue
  fi
  if [ "$cur" -lt 0 ]; then
    echo "explain-error: patterns.txt: key outside an entry: $line" >&2; load_err=1; continue
  fi
  case "$key" in
    area) E_AREA[cur]="$val" ;;
    match) M_RE+=("$val"); M_ENTRY+=("$cur"); E_NMATCH[cur]=$((E_NMATCH[cur] + 1)) ;;
    title) E_TITLE[cur]="$val" ;;
    cause) E_CAUSE[cur]="$val" ;;
    confirm) E_CONFIRM[cur]="$val" ;;
    fix) E_FIX[cur]="$val" ;;
    see) E_SEE[cur]="$val" ;;
    evidence) E_EVID[cur]="$val" ;;
    example) E_EX[cur]+="$val"$'\n' ;;
    *) echo "explain-error: patterns.txt: unknown key '$key' in ${E_ID[cur]}" >&2; load_err=1 ;;
  esac
done < "$db"

# ---- helpers ----------------------------------------------------------------------------
# match_text <text>: sets MATCHED (array of entry indexes, file order, no duplicates)
match_text() {
  local text="$1" k e
  local -A hit=()
  MATCHED=()
  for k in "${!M_RE[@]}"; do
    e=${M_ENTRY[k]}
    [ -n "${hit[$e]:-}" ] && continue
    if [[ $text =~ ${M_RE[k]} ]]; then hit[$e]=1; fi
  done
  for e in $(printf '%s\n' "${!hit[@]}" | sort -n); do MATCHED+=("$e"); done
}

print_entry() {
  local i=$1 extra="${2:-}"
  printf '[%s] (%s) %s%s\n' "${E_ID[i]}" "${E_AREA[i]:-?}" "${E_TITLE[i]:-}" "$extra"
  printf '  cause:    %s\n' "${E_CAUSE[i]:-}"
  printf '  confirm:  %s\n' "${E_CONFIRM[i]:-}"
  printf '  fix:      %s\n' "${E_FIX[i]:-}"
  printf '  see:      %s/%s\n' "$skill_rel" "${E_SEE[i]:-SKILL.md}"
  printf '  evidence: %s\n' "${E_EVID[i]:-}"
}

short() { local s="$1"; s="${s//$'\t'/ }"; [ ${#s} -gt 160 ] && s="${s:0:157}..."; printf '%s' "$s"; }

# ---- modes ------------------------------------------------------------------------------
mode="" brief=0 want_id=""
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --list) mode=list ;;
  --self-test) mode=selftest ;;
  --id) mode=id; want_id="${2:-}"; [ -n "$want_id" ] || { usage >&2; exit 2; } ;;
  --brief) brief=1; [ "${2:-}" = "-" ] || { echo "explain-error: --brief needs '-' (stdin)" >&2; exit 2; }; mode=stdin ;;
  -) mode=stdin ;;
  '') usage >&2; exit 2 ;;
  *) mode=one ;;
esac

if [ "$load_err" -ne 0 ] && [ "$mode" != selftest ]; then
  echo "explain-error: patterns.txt has errors (run --self-test)" >&2; exit 2
fi

case "$mode" in
  list)
    for ((i = 0; i < n; i++)); do printf '%s\t%s\t%s\n' "${E_ID[i]}" "${E_AREA[i]:-?}" "${E_TITLE[i]:-}"; done
    exit 0 ;;

  id)
    i="${ID_INDEX[$want_id]:-}"
    [ -n "$i" ] || { echo "explain-error: no entry with id '$want_id' (see --list)" >&2; exit 1; }
    print_entry "$i"; exit 0 ;;

  one)
    text="$*"
    match_text "$text"
    if [ ${#MATCHED[@]} -eq 0 ]; then
      echo "explain-error: UNKNOWN - no playbook entry matches: $(short "$text")" >&2
      echo "explain-error: next: triage by area in $skill_rel/SKILL.md section 1; if it is new and real, add an entry to patterns.txt (with an example) and re-run --self-test" >&2
      exit 1
    fi
    first=1
    for i in "${MATCHED[@]}"; do
      [ $first -eq 1 ] || echo
      first=0
      print_entry "$i"
    done
    exit 0 ;;

  stdin)
    declare -A CNT=() FIRST=()
    total=0 unknown=0
    while IFS= read -r l || [ -n "$l" ]; do
      l="${l%$'\r'}"
      [ -z "$l" ] && continue
      total=$((total + 1))
      match_text "$l"
      if [ ${#MATCHED[@]} -eq 0 ]; then unknown=$((unknown + 1)); continue; fi
      for i in "${MATCHED[@]}"; do
        CNT[$i]=$(( ${CNT[$i]:-0} + 1 ))
        [ -n "${FIRST[$i]:-}" ] || FIRST[$i]="$l"
      done
    done
    if [ ${#CNT[@]} -eq 0 ]; then
      echo "explain-error: UNKNOWN - none of $total line(s) matched a playbook entry" >&2
      exit 1
    fi
    order=$(for i in "${!CNT[@]}"; do printf '%s\t%s\n' "${CNT[$i]}" "$i"; done | sort -t$'\t' -k1,1nr -k2,2n | cut -f2)
    first=1
    for i in $order; do
      if [ $brief -eq 1 ]; then
        printf '%s\t%s\t%s\n' "${E_ID[i]}" "${CNT[$i]}" "${E_TITLE[i]:-}"
      else
        [ $first -eq 1 ] || echo
        first=0
        print_entry "$i" "  [${CNT[$i]} line(s)]"
        printf '  e.g.:     %s\n' "$(short "${FIRST[$i]}")"
      fi
    done
    [ $brief -eq 1 ] || printf '\n%s line(s) read, %s matched no entry\n' "$total" "$unknown"
    exit 0 ;;

  selftest)
    fail=$load_err nex=0
    for k in "${!M_RE[@]}"; do
      rc=0; [[ "" =~ ${M_RE[k]} ]] || rc=$?
      if [ "$rc" -eq 2 ]; then echo "FAIL invalid regex in ${E_ID[${M_ENTRY[k]}]}: ${M_RE[k]}"; fail=1; fi
    done
    for ((i = 0; i < n; i++)); do
      for f in E_AREA E_TITLE E_CAUSE E_CONFIRM E_FIX E_SEE E_EVID; do
        declare -n ref="$f"
        if [ -z "${ref[i]:-}" ]; then echo "FAIL ${E_ID[i]}: missing ${f#E_}"; fail=1; fi
        unset -n ref
      done
      [ "${E_NMATCH[i]}" -gt 0 ] || { echo "FAIL ${E_ID[i]}: no match line"; fail=1; }
      [ -n "${E_EX[i]}" ] || { echo "FAIL ${E_ID[i]}: no example"; fail=1; continue; }
      while IFS= read -r ex; do
        [ -z "$ex" ] && continue
        nex=$((nex + 1))
        match_text "$ex"
        own=0
        for j in "${MATCHED[@]}"; do [ "$j" -eq "$i" ] && own=1; done
        if [ $own -eq 0 ]; then echo "FAIL ${E_ID[i]}: example does not match its own entry: $(short "$ex")"; fail=1; fi
      done <<< "${E_EX[i]}"
    done
    if [ "$fail" -ne 0 ]; then echo "self-test: FAILED ($n entries, ${#M_RE[@]} patterns, $nex examples)"; exit 1; fi
    echo "self-test: OK ($n entries, ${#M_RE[@]} patterns, $nex examples)"
    exit 0 ;;
esac
