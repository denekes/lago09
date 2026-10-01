#!/usr/bin/env bash
# actionlint-local.sh — lint .github/workflows with actionlint (+ shellcheck for run: blocks)
# without installing anything system-wide. Tools are downloaded once (sha256-verified) into
# ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/tools/. Read-only on the repo.
#
# Usage (from anywhere inside the repo):
#   .claude/skills/release-and-images/scripts/actionlint-local.sh              # summary + compare to baseline
#   .../actionlint-local.sh --full                                             # also print every finding
#   .../actionlint-local.sh --strict                                           # exit 1 on ANY finding
#   .../actionlint-local.sh --no-shellcheck                                    # actionlint rules only
#   .../actionlint-local.sh --files ".github/workflows/release.yml"             # lint a subset (space-separated)
#
# Pinned tools (bump deliberately, then re-measure BASELINE): actionlint 1.7.7, shellcheck 0.11.0.
# BASELINE = 23 findings at HEAD 5308258 (as of 2026-10-01): 3 [action] (checkout@v3 x2,
# setup-go@v4 in events-processor-tests.yml) + 20 [shellcheck] (SC2086/SC2046 quoting).
# Output: per-rule and per-file counts, then "# findings=N baseline=23".
# Exit: 0 findings <= baseline (no NEW findings; with --strict: zero findings); 1 more findings
#       than baseline (or any with --strict); 2 usage; 3 tool download / checksum failure.
set -euo pipefail
AL_VER=1.7.7; SC_VER=0.11.0; BASELINE=23
full=0; strict=0; use_sc=1; files=""
need() { [ -n "$2" ] || { echo "actionlint-local: $1" >&2; exit 2; }; }   # missing option value = usage error
while [ $# -gt 0 ]; do
  case "$1" in
    --full)          full=1; shift;;
    --strict)        strict=1; shift;;
    --no-shellcheck) use_sc=0; shift;;
    --files)         need "--files needs a list" "${2:-}"; files="$2"; shift 2;;
    -h|--help)       awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0;;
    *) echo "actionlint-local: unknown argument: $1" >&2; exit 2;;
  esac
done
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git rev-parse --show-toplevel 2>/dev/null || git -C "$here" rev-parse --show-toplevel)"
tools="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/tools"
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)          al_arch=amd64; sc_arch=x86_64
                         al_sum=023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757
                         sc_sum=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198;;
  Linux/aarch64|Linux/arm64) al_arch=arm64; sc_arch=aarch64
                         al_sum=401942f9c24ed71e4fe71b76c7d638f66d8633575c4016efd2977ce7c28317d0
                         sc_sum=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588;;
  *) echo "actionlint-local: unsupported platform $(uname -s)/$(uname -m) (Linux amd64/arm64 only)" >&2; exit 3;;
esac

fetch() {  # fetch <url> <sha256> <dest-file>
  local tmpf; tmpf="$(mktemp "${TMPDIR:-/tmp}/al-dl.XXXXXX")"
  if ! curl -fsSL -o "$tmpf" "$1"; then rm -f "$tmpf"; echo "actionlint-local: download failed: $1" >&2; exit 3; fi
  if [ "$(sha256sum "$tmpf" | cut -d' ' -f1)" != "$2" ]; then
    rm -f "$tmpf"; echo "actionlint-local: sha256 mismatch for $1" >&2; exit 3
  fi
  mv -f "$tmpf" "$3"
}
AL="$tools/actionlint-$AL_VER/actionlint"
if [ ! -x "$AL" ]; then
  mkdir -p "$tools/actionlint-$AL_VER"
  echo "actionlint-local: installing actionlint $AL_VER into $tools" >&2
  fetch "https://github.com/rhysd/actionlint/releases/download/v$AL_VER/actionlint_${AL_VER}_linux_$al_arch.tar.gz" "$al_sum" "$tools/actionlint-$AL_VER/al.tgz"
  tar -xzf "$tools/actionlint-$AL_VER/al.tgz" -C "$tools/actionlint-$AL_VER" actionlint
  rm -f "$tools/actionlint-$AL_VER/al.tgz"
fi
SC=""
if [ "$use_sc" = 1 ]; then
  SC="$tools/shellcheck-v$SC_VER/shellcheck"
  if [ ! -x "$SC" ]; then
    command -v xz >/dev/null || { echo "actionlint-local: xz is needed to unpack shellcheck (or use --no-shellcheck)" >&2; exit 3; }
    mkdir -p "$tools"
    echo "actionlint-local: installing shellcheck $SC_VER into $tools" >&2
    fetch "https://github.com/koalaman/shellcheck/releases/download/v$SC_VER/shellcheck-v$SC_VER.linux.$sc_arch.tar.xz" "$sc_sum" "$tools/sc.tar.xz"
    tar -xJf "$tools/sc.tar.xz" -C "$tools" "shellcheck-v$SC_VER/shellcheck"
    rm -f "$tools/sc.tar.xz"
  fi
fi

cd "$repo"
if [ -n "$files" ]; then read -r -a targets <<<"$files"; else targets=(.github/workflows/*.yml .github/workflows/*.yaml); fi
out="$("$AL" -no-color -pyflakes= -shellcheck="$SC" "${targets[@]}" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -gt 1 ]; then echo "$out" >&2; echo "actionlint-local: actionlint failed (exit $rc)" >&2; exit 3; fi
findings="$(grep -E '^[^ :]+:[0-9]+:[0-9]+: ' <<<"$out" || true)"
n="$(grep -c . <<<"$findings" || true)"
echo "actionlint $AL_VER, shellcheck $( [ -n "$SC" ] && echo "$SC_VER" || echo off ), files: ${#targets[@]}"
if [ "$n" -gt 0 ]; then
  echo "-- by rule"
  sed -E 's/.*\[([a-z-]+)\]$/\1/' <<<"$findings" | sort | uniq -c | sort -rn
  echo "-- by shellcheck code"
  { grep -o -E 'shellcheck reported issue in this script: SC[0-9]+' <<<"$findings" || true; } | sed 's/.*: //' | sort | uniq -c | sort -rn
  echo "-- by file"
  cut -d: -f1 <<<"$findings" | sort | uniq -c | sort -rn
  [ "$full" = 1 ] && { echo "-- findings"; echo "$findings"; }
fi
if [ -n "$files" ] || [ "$use_sc" = 0 ]; then echo "# findings=$n (baseline applies to the full default run only)"
else echo "# findings=$n baseline=$BASELINE"; fi
if [ "$strict" = 1 ]; then [ "$n" -eq 0 ]; exit $?; fi
if [ -z "$files" ] && [ "$use_sc" = 1 ] && [ "$n" -gt "$BASELINE" ]; then exit 1; fi
exit 0
