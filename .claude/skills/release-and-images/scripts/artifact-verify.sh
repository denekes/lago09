#!/usr/bin/env bash
# artifact-verify.sh — post-release check: are the images of a Lago release published,
# with the expected architectures, and where does `latest` point?
# Read-only (anonymous registry APIs). Needs network + curl + jq.
#
# Usage (from anywhere):
#   .claude/skills/release-and-images/scripts/artifact-verify.sh v1.53.0            # one release
#   .../artifact-verify.sh v1.53.0 --no-ghcr                                        # Docker Hub only
#   .../artifact-verify.sh --sweep [--from v1.44.0]                                 # presence matrix, all releases
#
# What is expected per release (as of 2026-10-01; see SKILL.md "Artifact matrix"):
#   docker.io/getlago/lago                   amd64+arm64  (this repo, release-docker-image.yml)
#   docker.io/getlago/lago-events-processor  amd64+arm64  (this repo, release-processors-image.yml)
#   docker.io/getlago/api                    amd64+arm64  (lago-api's own release.yml)
#   docker.io/getlago/front                  amd64+arm64  (lago-front release.yml -> this repo's reusable workflow @main)
#   ghcr.io/getlago/{api,front,events-processor}  amd64  (this repo, release-images.yml; only from v1.44.0)
# `latest` (getlago/lago, getlago/lago-events-processor only): must equal the newest vX.Y.Z tag
# of getlago/lago (git ls-remote). ECR images are private and cannot be checked from here.
#
# Output lines: OK | MISS | WARN | INFO | SKIP  <image:tag>  <details>
#   archs exclude "unknown" entries (buildx attestation manifests, not a platform).
# Sweep output: TSV matrix, "Y" present, "-" missing, "." not expected (GHCR before v1.44.0,
#   lago-events-processor before v1.32.0, getlago/lago before v1.21.0: docker/Dockerfile was
#   added by 52ab3b3 the day of v1.21.0).
# Exit: 0 everything expected is present with expected archs; 1 something missing / wrong arch /
#       latest wrong; 2 usage; 3 registry API or git ls-remote unreachable.
set -euo pipefail
ver=""; ghcr=1; sweep=0; from="v1.44.0"
need() { [ -n "$2" ] || { echo "artifact-verify: $1" >&2; exit 2; }; }   # missing option value = usage error
while [ $# -gt 0 ]; do
  case "$1" in
    --no-ghcr) ghcr=0; shift;;
    --sweep)   sweep=1; shift;;
    --from)    need "--from needs vX.Y.Z" "${2:-}"; from="$2"; shift 2;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0;;
    v*)        ver="$1"; shift;;
    *) echo "artifact-verify: unknown argument: $1" >&2; exit 2;;
  esac
done
semver='^v[0-9]+\.[0-9]+\.[0-9]+$'
if [ "$sweep" = 0 ] && ! [[ "$ver" =~ $semver ]]; then
  echo "artifact-verify: need a version vX.Y.Z or --sweep (see --help)" >&2; exit 2
fi
[[ "$from" =~ $semver ]] || { echo "artifact-verify: --from needs vX.Y.Z" >&2; exit 2; }
command -v jq >/dev/null || { echo "artifact-verify: jq is required" >&2; exit 2; }

HUB=https://hub.docker.com/v2/repositories
DH_REPOS="lago lago-events-processor api front"
GH_REPOS="api front events-processor"
bad=0
vge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }   # vge A B: A >= B

hub_tag() {  # hub_tag <repo> <tag> -> JSON or empty (404); exit 3 on transport error
  local code body
  body="$(curl -sS -w '\n%{http_code}' "$HUB/getlago/$1/tags/$2")" || { echo "artifact-verify: Docker Hub API unreachable" >&2; exit 3; }
  code="${body##*$'\n'}"; body="${body%$'\n'*}"
  case "$code" in 200) printf '%s' "$body";; 404) printf '';; *) echo "artifact-verify: Docker Hub HTTP $code for $1:$2" >&2; exit 3;; esac
}
ghcr_token() { curl -sS "https://ghcr.io/token?scope=repository:getlago/$1:pull" | jq -r '.token // empty'; }
ghcr_tags() {  # ghcr_tags <repo> -> one tag per line; return 3 on transport/API error
  local tok body; tok="$(ghcr_token "$1")" || return 3
  [ -n "$tok" ] || return 3
  body="$(curl -sS -H "Authorization: Bearer $tok" "https://ghcr.io/v2/getlago/$1/tags/list?n=10000")" || return 3
  jq -e '.tags | type == "array"' >/dev/null 2>&1 <<<"$body" || return 3   # error JSON, not a tag list
  jq -r '.tags[]' <<<"$body"
}
ghcr_archs() {  # ghcr_archs <repo> <tag> -> "amd64,arm64" or empty if missing
  local tok; tok="$(ghcr_token "$1")" || return 3
  curl -sS -H "Authorization: Bearer $tok" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/getlago/$1/manifests/$2" \
  | jq -r 'if .manifests then [.manifests[] | .platform.architecture | select(. != "unknown")] | unique | join(",")
           elif .config then "single-arch-manifest"
           elif (.errors[0].code // "") == "MANIFEST_UNKNOWN" then empty
           elif .errors then "API-ERROR:" + (.errors[0].code // "?") else empty end' 2>/dev/null || true
}
newest_lago_tag() {
  git ls-remote --tags https://github.com/getlago/lago 2>/dev/null | sed -n 's#.*refs/tags/##p' | sed 's/\^{}$//' \
    | grep -E "$semver" | sort -uV | tail -1
}

if [ "$sweep" = 1 ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/av.XXXXXX")"; trap 'rm -rf -- "$tmp"' EXIT
  for r in $DH_REPOS; do
    url="$HUB/getlago/$r/tags?page_size=100"
    : > "$tmp/dh-$r"
    while [ -n "$url" ] && [ "$url" != null ]; do
      page="$(curl -sS "$url")" || { echo "artifact-verify: Docker Hub API unreachable" >&2; exit 3; }
      if ! jq -e '.results | type == "array"' >/dev/null 2>&1 <<<"$page"; then   # e.g. 429 error JSON
        echo "artifact-verify: Docker Hub API error for getlago/$r: $(head -c 200 <<<"$page")" >&2; exit 3
      fi
      jq -r '.results[].name' <<<"$page" >> "$tmp/dh-$r"
      url="$(jq -r '.next // empty' <<<"$page")"
    done
  done
  if [ "$ghcr" = 1 ]; then
    for r in $GH_REPOS; do
      ghcr_tags "$r" > "$tmp/gh-$r" || { echo "artifact-verify: GHCR unreachable (use --no-ghcr)" >&2; exit 3; }
    done
  fi
  tags="$(git ls-remote --tags https://github.com/getlago/lago | sed -n 's#.*refs/tags/##p' | sed 's/\^{}$//' \
          | grep -E "$semver" | sort -uV)" || { echo "artifact-verify: git ls-remote failed" >&2; exit 3; }
  printf '# tag\thub:lago\thub:lago-events-processor\thub:api\thub:front'
  [ "$ghcr" = 1 ] && printf '\tghcr:api\tghcr:front\tghcr:events-processor'
  printf '\n'
  rows=0; miss=0
  for t in $tags; do
    vge "$t" "$from" || continue
    rows=$((rows+1)); line="$t"; rowbad=0
    for r in $DH_REPOS; do
      if grep -qxF "$t" "$tmp/dh-$r"; then line="$line	Y"
      elif [ "$r" = lago-events-processor ] && ! vge "$t" v1.32.0; then line="$line	."
      elif [ "$r" = lago ] && ! vge "$t" v1.21.0; then line="$line	."
      else line="$line	-"; rowbad=1; fi
    done
    if [ "$ghcr" = 1 ]; then
      for r in $GH_REPOS; do
        if grep -qxF "$t" "$tmp/gh-$r"; then line="$line	Y"
        elif ! vge "$t" v1.44.0; then line="$line	."
        else line="$line	-"; rowbad=1; fi
      done
    fi
    echo "$line"; miss=$((miss+rowbad))
  done
  echo "# releases=$rows with-missing-artifacts=$miss"
  [ "$miss" -eq 0 ]; exit $?
fi

# ---- single release ----
for r in $DH_REPOS; do
  j="$(hub_tag "$r" "$ver")"
  if [ -z "$j" ]; then
    echo "MISS  docker.io/getlago/$r:$ver  (Docker Hub 404)"; bad=$((bad+1)); continue
  fi
  archs="$(jq -r '[.images[] | select(.architecture != "unknown") | .architecture] | unique | join(",")' <<<"$j")"
  when="$(jq -r '.last_updated' <<<"$j")"; dig="$(jq -r '.digest // "-"' <<<"$j")"
  if [ "$archs" = "amd64,arm64" ]; then echo "OK    docker.io/getlago/$r:$ver  $archs  pushed=$when  ${dig:0:19}"
  else echo "WARN  docker.io/getlago/$r:$ver  archs=$archs (expected amd64,arm64)  pushed=$when"; bad=$((bad+1)); fi
done

newest="$(newest_lago_tag)" || true
for r in lago lago-events-processor; do
  lj="$(hub_tag "$r" latest)"; vj="$(hub_tag "$r" "$ver")"
  ld="$(jq -r '.digest // empty' <<<"${lj:-{\}}")"; vd="$(jq -r '.digest // empty' <<<"${vj:-{\}}")"
  if [ -z "$newest" ]; then echo "INFO  docker.io/getlago/$r:latest  newest lago tag unknown (git ls-remote failed)"; continue; fi
  if [ "$ver" = "$newest" ]; then
    if [ -n "$ld" ] && [ "$ld" = "$vd" ]; then echo "OK    docker.io/getlago/$r:latest  == $ver (newest release)"
    else echo "WARN  docker.io/getlago/$r:latest  != $ver although $ver is the newest release"; bad=$((bad+1)); fi
  else
    if [ -n "$ld" ] && [ "$ld" = "$vd" ]; then
      echo "WARN  docker.io/getlago/$r:latest  == $ver but newest release is $newest (latest went backwards)"; bad=$((bad+1))
    else echo "INFO  docker.io/getlago/$r:latest  != $ver (expected: $ver is not the newest release, $newest is)"; fi
  fi
done

if [ "$ghcr" = 1 ]; then
  if ! vge "$ver" v1.44.0; then
    echo "SKIP  ghcr.io/getlago/{api,front,events-processor}:$ver  (GHCR pipeline publishes from v1.44.0 on)"
  else
    for r in $GH_REPOS; do
      if ! ghcr_token "$r" >/dev/null 2>&1; then echo "artifact-verify: GHCR unreachable" >&2; exit 3; fi
      a="$(ghcr_archs "$r" "$ver")"
      if [[ "$a" == API-ERROR:* ]]; then echo "artifact-verify: GHCR ${a} for $r:$ver" >&2; exit 3; fi
      if [ -z "$a" ]; then echo "MISS  ghcr.io/getlago/$r:$ver"; bad=$((bad+1))
      elif [ "$a" = amd64 ]; then echo "OK    ghcr.io/getlago/$r:$ver  amd64 (amd64-only by design: release-images.yml platforms: amd64)"
      else echo "INFO  ghcr.io/getlago/$r:$ver  archs=$a (workflow builds amd64 only; check release-images.yml)"; fi
    done
  fi
fi
echo "# problems=$bad"
[ "$bad" -eq 0 ]
