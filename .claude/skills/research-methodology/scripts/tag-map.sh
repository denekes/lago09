#!/usr/bin/env bash
# tag-map.sh — print tag -> commit tables for getlago/lago, lago-api, lago-front from
# `git ls-remote --tags` (the history clone made by history-setup.sh from the fork has
# NO tags, so this is the only reliable tag source). Read-only; needs network.
#
# Usage:
#   .claude/skills/research-methodology/scripts/tag-map.sh                 # all 3 repos
#   .../tag-map.sh --repo api --match '^v1\.5'                             # filter tags (ERE)
#   .../tag-map.sh --gitlinks --match '^v1\.5[0-3]'                        # umbrella tags + api/front pins
#   .../tag-map.sh --gitlinks --history "$H"                               # explicit history clone
#
# Output (TSV, sorted by version):
#   default:    repo  tag  sha40
#   --gitlinks: tag  sha7  commit-date  main|off-main  api=<sha7>(<api tags>|untagged)  front=...
#               off-main = tag commit is not an ancestor of the history clone's HEAD (e.g. the
#               v1.40.1 maintenance release, cut on a side branch). The blob-less clone fetches
#               such commits lazily by full sha; "not-in-history" if even that fails.
#               "-" when the gitlink is absent in that commit.
# Annotated tags are peeled (the ^{} commit wins). Interpretation of pin mismatches
# (release audit) belongs to the release-and-images skill.
# Exit: 0 ok; 1 ls-remote failed (network/auth); 2 usage error.
set -euo pipefail
repo_sel=all; match='.'; gitlinks=0; hist=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     repo_sel="${2:?--repo needs lago|api|front|all}"; shift 2;;
    --match)    match="${2:?--match needs an ERE}"; shift 2;;
    --gitlinks) gitlinks=1; shift;;
    --history)  hist="${2:?--history needs a path}"; shift 2;;
    -h|--help)  sed -n '2,21p' "$0"; exit 0;;
    *) echo "tag-map: unknown argument: $1" >&2; exit 2;;
  esac
done
case "$repo_sel" in lago|api|front|all) ;; *) echo "tag-map: --repo must be lago|api|front|all" >&2; exit 2;; esac

tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT

# fetch_tags <short> <github repo> -> writes "$tmp/<short>.tsv" as "tag<TAB>sha40" (peeled)
fetch_tags() {
  local short="$1" gh="$2"
  if ! GIT_TERMINAL_PROMPT=0 git ls-remote --tags "https://github.com/getlago/$gh" > "$tmp/$short.raw"; then
    echo "tag-map: git ls-remote failed for getlago/$gh" >&2; exit 1
  fi
  awk '{ ref=$2; sub("^refs/tags/", "", ref)
         if (ref ~ /\^\{\}$/) { sub(/\^\{\}$/, "", ref); peeled[ref]=$1 } else { plain[ref]=$1 } }
       END { for (t in plain) print t "\t" ((t in peeled) ? peeled[t] : plain[t]) }' \
    "$tmp/$short.raw" | sort -t "$(printf '\t')" -k1,1V > "$tmp/$short.tsv"
}

# filter_tags <tsv>: keep rows whose TAG field matches --match (ERE; anchors apply to the tag).
# The regex goes through ENVIRON so awk does not rewrite backslash escapes such as \.
filter_tags() { RE="$match" awk -F '\t' 'BEGIN { re = ENVIRON["RE"] } $1 ~ re' "$1"; }

if [ "$gitlinks" = 0 ]; then
  for r in lago api front; do
    [ "$repo_sel" = all ] || [ "$repo_sel" = "$r" ] || continue
    case "$r" in lago) gh=lago;; api) gh=lago-api;; front) gh=lago-front;; esac
    fetch_tags "$r" "$gh"
    filter_tags "$tmp/$r.tsv" | sed "s/^/$r\t/"
  done
  exit 0
fi

# --gitlinks: umbrella tags with the api/front gitlinks recorded in each tagged commit
if [ -z "$hist" ]; then
  hist="$("$(dirname "$0")/history-setup.sh")"
fi
fetch_tags lago lago; fetch_tags api lago-api; fetch_tags front lago-front
names_for() { # names_for <short> <sha40> -> comma list of tags pointing at sha, or "untagged"
  local n; n="$(awk -F '\t' -v s="$2" '$2==s {printf "%s%s", (c++ ? "," : ""), $1}' "$tmp/$1.tsv")"
  printf '%s' "${n:-untagged}"
}
filter_tags "$tmp/lago.tsv" | while IFS="$(printf '\t')" read -r tag sha; do
  if ! git -C "$hist" rev-parse -q --verify "$sha^{commit}" >/dev/null 2>&1; then
    printf '%s\t%s\tnot-in-history\n' "$tag" "${sha:0:7}"; continue
  fi
  date="$(git -C "$hist" log -1 --format=%cs "$sha")"
  onmain=off-main; git -C "$hist" merge-base --is-ancestor "$sha" HEAD 2>/dev/null && onmain=main
  out="$tag\t${sha:0:7}\t$date\t$onmain"
  for sub in api front; do
    g="$(git -C "$hist" rev-parse -q --verify "$sha:$sub" 2>/dev/null || true)"
    if [ -z "$g" ]; then out="$out\t$sub=-"; else out="$out\t$sub=${g:0:7}($(names_for "$sub" "$g"))"; fi
  done
  printf '%b\n' "$out"
done
