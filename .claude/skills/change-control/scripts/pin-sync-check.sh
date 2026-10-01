#!/usr/bin/env bash
# pin-sync-check.sh — assert that the multi-location toolchain pins of events-processor
# move together (change-control N3).
#
# Usage:
#   pin-sync-check.sh                 # check the working tree of the repo you are in
#   pin-sync-check.sh --index         # check what is STAGED (git show :path)
#   pin-sync-check.sh --rev <rev>     # check a commit (works on the bare history clone too)
#   pin-sync-check.sh -C <dir> ...    # run against another checkout / bare clone
#   pin-sync-check.sh -q ...          # print only FAIL/WARN lines and the summary
#
# Checks (each prints OK | FAIL | WARN | INFO with file:line):
#   PS1 lago-expression ref: identical in events-processor/Dockerfile, Dockerfile.dev,
#      Dockerfile.staging (ARG LAGO_EXPRESSION_REF) and the CI checkout `ref:`.
#      A location that exists but carries no ref is FAIL (unpinned clone, see 07d1d4d).
#   PS2 Rust image: `FROM rust:X` identical in Dockerfile and Dockerfile.dev (5077151 -> e8bbd60).
#      CI builds with the runner's default Rust: INFO only.
#   PS3 Go: go.mod `go`, mise.toml `go`, `FROM golang:` x2, CI `go-version` share one
#      major.minor (FAIL otherwise); patch-level differences are INFO. Floating base images
#      (golang:1.25, rust:1.85) are checked at the spelled value only: patch drift on Docker
#      Hub is an accepted residual (change-control N3).
#   PS4 expression-go in go.mod: v0.1.4 is expected (no expression-go/v0.2.0 tag exists;
#      the cgo surface is identical). Any other value is WARN: confirm the tag exists.
#   PS5 `go install ...@latest` in events-processor Dockerfiles: FAIL (d589940).
# The pre-2025-03-21 directory name `events_processor/` is handled for old revisions.
#
# Read-only. Exit codes: 0 = no FAIL, 1 = at least one FAIL, 2 = usage or git error.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

dir="" mode="worktree" rev="" quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    -C) dir="${2:?-C needs a directory}"; shift 2 ;;
    --index) mode="index"; shift ;;
    --rev) mode="rev"; rev="${2:?--rev needs a revision}"; shift 2 ;;
    -q) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "pin-sync-check: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

G=(git -c gc.auto=0)
[ -n "$dir" ] && G+=(-C "$dir")
"${G[@]}" rev-parse --git-dir >/dev/null 2>&1 || { echo "pin-sync-check: not a git repository: ${dir:-$PWD}" >&2; exit 2; }
if [ "$mode" = worktree ]; then
  top="$("${G[@]}" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "pin-sync-check: no working tree here (bare clone?); use --rev <rev>" >&2; exit 2; }
fi
if [ "$mode" = rev ]; then
  "${G[@]}" rev-parse --verify -q "$rev^{commit}" >/dev/null || { echo "pin-sync-check: unknown revision: $rev" >&2; exit 2; }
fi

# readf <path>: print file content from the selected source; return 1 if absent.
readf() {
  case "$mode" in
    worktree) [ -f "$top/$1" ] && cat "$top/$1" ;;
    index) "${G[@]}" show ":$1" 2>/dev/null ;;
    rev) "${G[@]}" show "$rev:$1" 2>/dev/null ;;
  esac
}
exists() { readf "$1" >/dev/null 2>&1; }

EP=events-processor
exists "$EP/go.mod" || EP=events_processor
if ! exists "$EP/go.mod"; then
  echo "INFO  no events-processor/ (or events_processor/) in this tree: nothing to check"
  echo "SUMMARY pin-sync-check: 0 FAIL, 0 WARN"
  exit 0
fi
CI=.github/workflows/events-processor-tests.yml

fails=0 warns=0
say() { # level msg
  case "$1" in FAIL) fails=$((fails+1)) ;; WARN) warns=$((warns+1)) ;; esac
  if [ "$quiet" = 0 ] || [ "$1" = FAIL ] || [ "$1" = WARN ]; then printf '%-5s %s\n' "$1" "$2"; fi
}
# first_match <path> <grep ERE> <sed ERE whose \1 is the value>: prints "line<TAB>value"
first_match() {
  local out
  out="$(readf "$1" 2>/dev/null | grep -nE "$2" | head -n1)" || true
  [ -z "$out" ] && return 1
  printf '%s\t%s\n' "${out%%:*}" "$(printf '%s' "${out#*:}" | sed -nE "s/$3/\1/p")"
}

src_label() { case "$mode" in worktree) echo "working tree" ;; index) echo "index (staged)" ;; rev) echo "rev $("${G[@]}" rev-parse --short "$rev")" ;; esac; }
[ "$quiet" = 0 ] && echo "INFO  pin-sync-check on $(src_label); events-processor dir: $EP/"

# ---- PS1 lago-expression ref --------------------------------------------------------
declare -a p1_vals=() p1_locs=()
p1_add() { # file grep sed
  local f="$1" r
  if ! exists "$f"; then say INFO "PS1 $f absent in this tree (skipped)"; return; fi
  if r="$(first_match "$f" "$2" "$3")" && [ -n "${r#*$'\t'}" ]; then
    p1_vals+=("${r#*$'\t'}"); p1_locs+=("$f:${r%%$'\t'*}")
  else
    say FAIL "PS1 $f builds lago-expression without a pinned ref (no tag found)"
  fi
}
p1_add "$EP/Dockerfile"         'git checkout v[0-9]' '.*git checkout (v[0-9][0-9A-Za-z.+-]*).*'
p1_add "$EP/Dockerfile.dev"     'git checkout v[0-9]' '.*git checkout (v[0-9][0-9A-Za-z.+-]*).*'
p1_add "$EP/Dockerfile.staging" 'LAGO_EXPRESSION_REF=' '.*LAGO_EXPRESSION_REF=([^[:space:]]+).*'
if exists "$CI"; then
  # the `ref:` that follows `repository: getlago/lago-expression`
  ciref="$(readf "$CI" | awk '/repository:[[:space:]]*getlago\/lago-expression/{f=1} f && /ref:/{sub(/.*ref:[[:space:]]*/,""); gsub(/["'\'']/,""); print NR"\t"$0; exit}')"
  if [ -n "$ciref" ]; then p1_vals+=("${ciref#*$'\t'}"); p1_locs+=("$CI:${ciref%%$'\t'*}")
  elif readf "$CI" | grep -q 'getlago/lago-expression'; then say FAIL "PS1 $CI checks out lago-expression without ref:"
  fi
fi
if [ "${#p1_vals[@]}" -gt 0 ]; then
  uniq_p1="$(printf '%s\n' "${p1_vals[@]}" | sort -u)"
  detail=""; for i in "${!p1_vals[@]}"; do detail+=" ${p1_locs[$i]}=${p1_vals[$i]}"; done
  if [ "$(printf '%s\n' "$uniq_p1" | wc -l)" -eq 1 ]; then
    say OK "PS1 lago-expression ref ${p1_vals[0]} in ${#p1_vals[@]} places:$detail"
  else
    say FAIL "PS1 lago-expression refs disagree:$detail"
  fi
fi

# ---- PS2 Rust image -----------------------------------------------------------------
declare -a rs_vals=() rs_locs=()
for f in "$EP/Dockerfile" "$EP/Dockerfile.dev"; do
  exists "$f" || continue
  if r="$(first_match "$f" '^FROM[[:space:]]+rust:' '^FROM[[:space:]]+rust:([^[:space:]]+).*')"; then
    rs_vals+=("${r#*$'\t'}"); rs_locs+=("$f:${r%%$'\t'*}")
  fi
done
if [ "${#rs_vals[@]}" -gt 0 ]; then
  detail=""; for i in "${!rs_vals[@]}"; do detail+=" ${rs_locs[$i]}=rust:${rs_vals[$i]}"; done
  if [ "$(printf '%s\n' "${rs_vals[@]}" | sort -u | wc -l)" -eq 1 ]; then say OK "PS2 Rust image identical:$detail"
  else say FAIL "PS2 Rust images disagree (the lago-expression pin set includes the Rust image):$detail"; fi
fi
exists "$CI" && readf "$CI" | grep -q 'cargo build' && say INFO "PS2 $CI builds with the runner's default Rust (not pinned)"
exists "$EP/Dockerfile.staging" && say INFO "PS2/PS3 $EP/Dockerfile.staging takes Rust and Go from its BUILD_IMAGE (not checked here)"

# ---- PS3 Go version set -------------------------------------------------------------
declare -a go_vals=() go_locs=()
go_add() { local r; exists "$1" || return 0; if r="$(first_match "$1" "$2" "$3")" && [ -n "${r#*$'\t'}" ]; then go_vals+=("${r#*$'\t'}"); go_locs+=("$1:${r%%$'\t'*}"); fi; }
go_add "$EP/go.mod"         '^go [0-9]'                 '^go ([0-9][0-9.]*).*'
go_add "$EP/mise.toml"      '^go[[:space:]]*='          '^go[[:space:]]*=[[:space:]]*"?([0-9][0-9.]*)"?.*'
go_add "$EP/Dockerfile"     '^FROM[[:space:]]+golang:'  '^FROM[[:space:]]+golang:([0-9][0-9.]*).*'
go_add "$EP/Dockerfile.dev" '^FROM[[:space:]]+golang:'  '^FROM[[:space:]]+golang:([0-9][0-9.]*).*'
go_add "$CI"                'go-version:'               '.*go-version:[[:space:]]*"?([0-9][0-9.x]*)"?.*'
if [ "${#go_vals[@]}" -gt 0 ]; then
  detail=""; for i in "${!go_vals[@]}"; do detail+=" ${go_locs[$i]}=${go_vals[$i]}"; done
  minors="$(printf '%s\n' "${go_vals[@]}" | awk -F. '{print $1"."$2}' | sort -u)"
  if [ "$(printf '%s\n' "$minors" | wc -l)" -eq 1 ]; then
    say OK "PS3 Go $(printf '%s' "$minors") everywhere (${#go_vals[@]} places):$detail"
    [ "$(printf '%s\n' "${go_vals[@]}" | sort -u | wc -l)" -gt 1 ] && say INFO "PS3 patch-level spellings differ (informational):$detail"
  else
    say FAIL "PS3 Go major.minor disagree:$detail"
  fi
fi

# ---- PS4 expression-go module ---------------------------------------------------------
if r="$(first_match "$EP/go.mod" 'lago-expression/expression-go' '.*expression-go[[:space:]]+(v[^[:space:]]+).*')"; then
  v="${r#*$'\t'}"
  if [ "$v" = v0.1.4 ]; then
    say OK "PS4 $EP/go.mod:${r%%$'\t'*} expression-go $v (expected; do NOT 'fix' to the .so ref: no expression-go/v0.2.0 tag, ABI identical)"
  else
    say WARN "PS4 $EP/go.mod:${r%%$'\t'*} expression-go $v: confirm the tag expression-go/$v exists in getlago/lago-expression"
  fi
fi

# ---- PS5 floating dev tools --------------------------------------------------------
p5=0
for f in "$EP/Dockerfile" "$EP/Dockerfile.dev" "$EP/Dockerfile.staging"; do
  exists "$f" || continue
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    p5=$((p5+1))
    say FAIL "PS5 $f:${m%%:*} floating tool version: $(printf '%s' "${m#*:}" | sed -E 's/^[[:space:]]+//')"
  done < <(readf "$f" | grep -nE 'go install [^[:space:]]+@latest' || true)
done
[ "$p5" -eq 0 ] && say OK "PS5 no 'go install ...@latest' in $EP Dockerfiles"

echo "SUMMARY pin-sync-check: $fails FAIL, $warns WARN"
[ "$fails" -eq 0 ]
