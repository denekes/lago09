#!/usr/bin/env bash
# release-pin-audit.sh — audit getlago/lago release tags (or a release candidate commit):
# do the `api` / `front` gitlinks point at the lago-api / lago-front commits that carry
# the SAME tag name, and does docker-compose.yml name getlago/api:<tag> + getlago/front:<tag>?
# Read-only. Needs network (git ls-remote x3; lazy blob fetches in the history clone).
#
# Usage (from anywhere inside the repo):
#   .claude/skills/release-and-images/scripts/release-pin-audit.sh                 # v-tags >= v1.24.0
#   .../release-pin-audit.sh --from v1.44.0                                        # v-tags >= v1.44.0
#   .../release-pin-audit.sh --tag v1.52.1                                         # one published tag
#   .../release-pin-audit.sh --candidate HEAD v1.54.0                              # PRE-TAG check of a commit
#   .../release-pin-audit.sh --all                                                 # every vX.Y.Z tag (old ones are noisy)
#   --no-compose   skip the docker-compose.yml check (no blob fetches)
#
# Output: TSV, one row per audited tag:
#   tag  sha7  date  main|off-main|candidate  api=<sha7>(<lago-api tags>)  front=<sha7>(<lago-front tags>)  compose=<api>/<front>  VERDICT
# VERDICT: OK, or a space-separated list of problems:
#          PIN-MISMATCH(api|front)     gitlink is not the commit of the same-named upstream tag (which exists)
#          NO-UPSTREAM-TAG(api|front)  lago-api / lago-front has no tag of that name (e.g. front v1.41.1..3)
#          COMPOSE-MISMATCH            docker-compose.yml names another getlago/api|front version
#          NOT-IN-HISTORY              the tag commit is not in the history clone (off-fork commit)
# A summary line "# audited=N ok=N not-ok=N" ends the output.
# Exit: 0 every audited row OK; 1 at least one non-OK row; 2 usage error; 3 network / ls-remote failure.
set -euo pipefail
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"

from="v1.24.0"; one=""; cand_ref=""; cand_ver=""; compose=1; all=0
need() { [ -n "$2" ] || { echo "release-pin-audit: $1" >&2; exit 2; }; }   # missing option value = usage error
while [ $# -gt 0 ]; do
  case "$1" in
    --from)       need "--from needs vX.Y.Z" "${2:-}"; from="$2"; shift 2;;
    --tag)        need "--tag needs vX.Y.Z" "${2:-}"; one="$2"; shift 2;;
    --candidate)  need "--candidate needs <ref> <vX.Y.Z>" "${2:-}"; need "--candidate needs <ref> <vX.Y.Z>" "${3:-}"
                  cand_ref="$2"; cand_ver="$3"; shift 3;;
    --all)        all=1; shift;;
    --no-compose) compose=0; shift;;
    -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0;;
    *) echo "release-pin-audit: unknown argument: $1" >&2; exit 2;;
  esac
done
semver='^v[0-9]+\.[0-9]+\.[0-9]+$'
for v in "$from" ${one:+"$one"} ${cand_ver:+"$cand_ver"}; do
  [[ "$v" =~ $semver ]] || { echo "release-pin-audit: not a vX.Y.Z version: $v" >&2; exit 2; }
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git rev-parse --show-toplevel 2>/dev/null || git -C "$here" rev-parse --show-toplevel)"
# Foundation script next to THIS script first (works on a release branch cut from a main
# that does not carry .claude/skills), else in the checkout being audited.
rm_dir="$(cd "$here/../.." && pwd)/research-methodology/scripts"
[ -x "$rm_dir/history-setup.sh" ] || rm_dir="$repo/.claude/skills/research-methodology/scripts"
H="$("$rm_dir/history-setup.sh")"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rpa.XXXXXX")"; trap 'rm -rf -- "$tmp"' EXIT

# tag -> commit (annotated tags: the peeled ^{} line wins)
lsr() {  # lsr <repo-name> <outfile>
  if ! git ls-remote --tags "https://github.com/getlago/$1" > "$tmp/$1.raw"; then
    echo "release-pin-audit: git ls-remote failed for getlago/$1 (network?)" >&2; exit 3
  fi
  awk '{t=$2; sub("refs/tags/","",t); if (t ~ /\^\{\}$/) {sub(/\^\{\}$/,"",t); peel[t]=$1} else {plain[t]=$1}}
       END {for (t in plain) print t"\t"((t in peel)?peel[t]:plain[t])}' "$tmp/$1.raw" > "$2"
}
lsr lago "$tmp/lago.map"; lsr lago-api "$tmp/api.map"; lsr lago-front "$tmp/front.map"

tags_at() {  # tags_at <mapfile> <sha40> -> "v1.2.3,v1.2.4" or "untagged"
  local r; r="$(awk -v s="$2" -F'\t' '$2==s {print $1}' "$1" | sort -V | paste -sd, -)"
  echo "${r:-untagged}"
}
has_tag() { awk -v t="$2" -F'\t' '$1==t {f=1} END {exit !f}' "$1"; }

audit_one() {  # audit_one <tag/version> <commit40> <gitdir>
  local t="$1" c="$2" g="$3" a f at ft br cv verdict date
  if ! git -C "$g" cat-file -e "$c^{commit}" 2>/dev/null; then
    printf '%s\t%s\t-\t-\t-\t-\t-\tNOT-IN-HISTORY\n' "$t" "${c:0:7}"; return 1
  fi
  date="$(git -C "$g" log -1 --format=%ad --date=short "$c")"
  if [ "$g" = "$repo" ]; then br=candidate
  elif git -C "$H" merge-base --is-ancestor "$c" HEAD 2>/dev/null; then br=main; else br=off-main; fi
  a="$(git -C "$g" rev-parse -q --verify "$c:api" 2>/dev/null || echo -)"
  f="$(git -C "$g" rev-parse -q --verify "$c:front" 2>/dev/null || echo -)"
  at="$(tags_at "$tmp/api.map" "$a")"; ft="$(tags_at "$tmp/front.map" "$f")"
  cv="skipped"
  if [ "$compose" = 1 ]; then
    cv="$(git -C "$g" show "$c:docker-compose.yml" 2>/dev/null \
          | sed -n -E 's#^[[:space:]]*image:[[:space:]]*getlago/(api|front):([^[:space:]]+).*#\2#p' | paste -sd/ -)"
    cv="${cv:--}"
  fi
  verdict=""
  side() {  # side <name> <tags-at-pin> <mapfile>
    if [[ ",$2," == *",$t,"* ]]; then return 0; fi
    if has_tag "$3" "$t"; then verdict="$verdict PIN-MISMATCH($1)"; else verdict="$verdict NO-UPSTREAM-TAG($1)"; fi
  }
  side api "$at" "$tmp/api.map"; side front "$ft" "$tmp/front.map"
  if [ "$compose" = 1 ] && [ "$cv" != "$t/$t" ]; then verdict="$verdict COMPOSE-MISMATCH"; fi
  verdict="${verdict# }"; verdict="${verdict:-OK}"
  printf '%s\t%s\t%s\t%s\tapi=%s(%s)\tfront=%s(%s)\tcompose=%s\t%s\n' \
    "$t" "${c:0:7}" "$date" "$br" "${a:0:7}" "$at" "${f:0:7}" "$ft" "$cv" "$verdict"
  [ "$verdict" = OK ]
}

header() { printf '# tag\tsha7\tdate\tbranch\tapi-gitlink(lago-api tags)\tfront-gitlink(lago-front tags)\tcompose api/front\tVERDICT\n'; }
n=0; bad=0
if [ -n "$cand_ref" ]; then
  # Candidate: resolve in the working clone first (it has the newest commits), else the history clone.
  if c="$(git -C "$repo" rev-parse -q --verify "$cand_ref^{commit}")"; then g="$repo"
  elif c="$(git -C "$H" rev-parse -q --verify "$cand_ref^{commit}")"; then g="$H"
  else echo "release-pin-audit: cannot resolve $cand_ref" >&2; exit 2; fi
  header; n=1; audit_one "$cand_ver" "$c" "$g" || bad=1
  if has_tag "$tmp/lago.map" "$cand_ver"; then
    echo "# WARNING: getlago/lago already has tag $cand_ver -> $(awk -v t="$cand_ver" -F'\t' '$1==t{print substr($2,1,7)}' "$tmp/lago.map")" >&2
  fi
else
  if [ -n "$one" ]; then
    has_tag "$tmp/lago.map" "$one" || { echo "release-pin-audit: getlago/lago has no tag $one" >&2; exit 2; }
    list="$one"
  else
    list="$(cut -f1 "$tmp/lago.map" | grep -E "$semver" | sort -V)"
    if [ "$all" = 0 ]; then
      list="$(printf '%s\n%s\n' "$list" "$from" | sort -uV | sed -n "/^${from//./\\.}\$/,\$p")"
      has_tag "$tmp/lago.map" "$from" || list="$(echo "$list" | grep -vxF "$from")"
    fi
  fi
  header
  for t in $list; do
    c="$(awk -v t="$t" -F'\t' '$1==t {print $2}' "$tmp/lago.map")"
    n=$((n+1)); audit_one "$t" "$c" "$H" || bad=$((bad+1))
  done
fi
echo "# audited=$n ok=$((n-bad)) not-ok=$bad"
[ "$bad" -eq 0 ]
