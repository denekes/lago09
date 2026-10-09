#!/usr/bin/env bash
# shellcheck shell=bash
# _lib.sh — shared helpers for the failure-archaeology scripts (hist.sh, incidents.sh, chain.sh).
# Source it; do not execute it. Read-only: every git call targets the history clone with
# auto-gc and auto-maintenance disabled, so lazy blob fetches never repack in the background.
#
# Provides:
#   fa_init            sets H (history clone path) or exits 3; honours $LAGO_HISTORY if set
#   G <git args>       git against $H (read-only usage only)
#   fa_expand_path P   prints rename-aware pathspecs for P (events-processor <-> events_processor)
#   fa_scope_specs S   prints pathspecs for scope S in {ep, infra, all}
#   fa_need FLAG VAL   exits 2 (usage) when an option's value is missing
#   FA_BUMP_RE         lower-case ERE matching release-bump subjects (hist.sh --no-bumps, incidents.sh)
#   FA_KEEP_RE         lower-case ERE of toolchain words; a subject matching it is never treated as a
#                      release bump (keeps e.g. "misc(Ruby): Bump version to 3.4.5")

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "_lib.sh is a library: source it from hist.sh / incidents.sh / chain.sh" >&2; exit 2
fi

FA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Lower-case EREs without backslashes (awk -v would mangle escapes); compare against tolower(subject).
# Checked 2026-10-01 against all 776 subjects: matches 275 release bumps (incl. "Bump version to
# v1.53.0", "misc: Bump version from 1.8.0 to 1.8.1", merges of bump-version branches); the
# bump-like subjects it leaves alone are toolchain, image or workflow changes.
FA_BUMP_RE='(bump|release|upgrade|update)[^a-z0-9]*(lago |api |front )?(versions?)?[^a-z0-9]*(from[^a-z]*v?[0-9.]+[^a-z0-9]*)?(to)?[^a-z0-9]*v?[.]?[0-9]+[.][0-9]+|^release:|chore.releas|misc: point|update docker tags|bump vesrion|^(misc: )?v?(ersion )?[0-9]+[.][0-9]+|^(misc: )?(bump|update)[a-z &]* versions?$|(update|bump)[a-z &]*(api|front|services|worker|images?|arm64)[a-z &]*(to|versions?)( |$)|bump to v[0-9]+-[0-9]+|^merge pull request #[0-9]+ from [^ ]*(bump|release-v?[0-9]|/v?[0-9]+[-.][0-9]+)'
FA_KEEP_RE='ruby|node|rust|golang|redis|clickhouse|postgres|expression|gotenberg|connect'

fa_die() { echo "${0##*/}: $1" >&2; exit "${2:-2}"; }

fa_need() { [ -n "${2:-}" ] || fa_die "$1 needs a value (see --help)"; }

fa_repo_root() { git -C "$FA_DIR" rev-parse --show-toplevel; }

fa_init() {
  if [ -n "${LAGO_HISTORY:-}" ]; then
    H="$LAGO_HISTORY"
  else
    local root setup
    root="$(fa_repo_root)" || fa_die "not inside a git checkout" 3
    setup="$root/.claude/skills/research-methodology/scripts/history-setup.sh"
    [ -x "$setup" ] || fa_die "missing $setup (research-methodology skill)" 3
    H="$("$setup")" || fa_die "history-setup.sh failed (network?)" 3
  fi
  [ -d "$H" ] || fa_die "history clone not found: $H" 3
  # Warn (do not fail) when the clone is behind the checkout's origin/main. Local WIP commits are
  # expected to be missing, so compare origin/main, and never trigger a lazy fetch for the check.
  local upstream
  upstream="$(git -C "$FA_DIR" rev-parse -q --verify origin/main 2>/dev/null || true)"
  if [ -n "$upstream" ] && ! GIT_NO_LAZY_FETCH=1 G cat-file -e "${upstream}^{commit}" 2>/dev/null; then
    echo "${0##*/}: warning: history clone lacks origin/main ${upstream:0:7}; run history-setup.sh --refresh" >&2
  fi
  export H
}

G() { git -c gc.auto=0 -c maintenance.auto=false -C "$H" "$@"; }

fa_expand_path() {
  local p="${1%/}"
  case "$p" in
    events-processor|events-processor/*) printf '%s\n%s\n' "$p" "events_processor${p#events-processor}" ;;
    events_processor|events_processor/*) printf '%s\n%s\n' "events-processor${p#events_processor}" "$p" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

fa_scope_specs() {
  case "$1" in
    ep)    printf '%s\n' events-processor events_processor ;;
    infra) printf '%s\n' . ':!events-processor' ':!events_processor' ;;
    all)   printf '%s\n' . ;;
    *)     fa_die "unknown scope: $1" ;;
  esac
}
