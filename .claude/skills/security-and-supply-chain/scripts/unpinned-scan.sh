#!/usr/bin/env bash
# unpinned-scan.sh - inventory of floating / unverified supply-chain references (read-only).
#
# Usage: unpinned-scan.sh [--repo DIR] [--summary] [--fail-on-latest]
#
# Sections and row format (tab-separated):
#   IMAGE  <class> <file:line> <ref as resolved>    class: LATEST | NO-TAG | MAJOR | MINOR | EXACT |
#                                                   DIGEST | LOCAL-BUILD | ARG-UNRESOLVED
#          (compose `image:` + Dockerfile `FROM`; ${VAR:-default} and Dockerfile ARG defaults resolved;
#           MAJOR = one numeric component (redis:7-alpine, traefik:v3), MINOR = two (golang:1.25),
#           EXACT = three or more (v25.2.10). Only DIGEST (@sha256:) is immutable.)
#   TOOL   <class> <file:line> <what>               class: AT-LATEST | VERSION-LATEST | CURL-PIPE-SH |
#                                                   GO-INSTALL-PARTIAL
#   ACTION <class> <file:line> <uses ref>           class: SHA | EXACT-TAG | MAJOR-TAG | LOCAL
#   CLONE  <class> <file:line> <what>               class: GIT-CLONE-TAG (git clone + checkout of a tag,
#                                                   no commit check) | CHECKOUT-REF (actions/checkout of
#                                                   another repository by tag/branch)
#   VENDOR <class> <path>                           class: JAR-NO-CHECKSUM | JAR-WITH-CHECKSUM
#   SOCK   DOCKER-SOCK <file:line>                  docker.sock mounted or used (root-equivalent on host)
#   SUMMARY ...
# Exit codes: 0 scan done; 1 --fail-on-latest and at least one LATEST/NO-TAG image or AT-LATEST/
#   VERSION-LATEST tool; 2 usage (unknown option or missing option value).
set -euo pipefail

REPO=""; SUMMARY_ONLY=0; FAIL_LATEST=0
need() { [ -n "$2" ] || { echo "$1" >&2; exit 2; }; }   # missing option value = usage (exit 2), never exit 1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "--repo needs a directory" "${2:-}"; REPO="$2"; shift 2 ;;
    --summary) SUMMARY_ONLY=1; shift ;;
    --fail-on-latest) FAIL_LATEST=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo; use --repo" >&2; exit 2; }
cd "$REPO"

declare -A COUNT=()
emit() { # kind class location detail
  COUNT["$1:$2"]=$(( ${COUNT["$1:$2"]:-0} + 1 ))
  [ "$SUMMARY_ONLY" = 1 ] || printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}"
}

classify_ref() { # image ref -> class
  local ref="$1" name tag ver n
  case "$ref" in *@sha256:*) echo DIGEST; return ;; esac
  case "$ref" in *'${'*|*'$'*) echo ARG-UNRESOLVED; return ;; esac
  name="${ref##*/}"
  if [[ "$name" != *:* ]]; then
    if [[ "$ref" == *_dev ]]; then echo LOCAL-BUILD; else echo NO-TAG; fi; return
  fi
  tag="${name##*:}"
  [ "$tag" = latest ] && { echo LATEST; return; }
  ver="${tag#v}"; ver="${ver%%-*}"
  if [[ ! "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then echo LATEST; return; fi
  n=$(awk -F. '{print NF}' <<< "$ver")
  case "$n" in 1) echo MAJOR ;; 2) echo MINOR ;; *) echo EXACT ;; esac
}

[ "$SUMMARY_ONLY" = 1 ] || echo "== IMAGE: compose image: and Dockerfile FROM =="
while IFS= read -r f; do
  if [[ "$f" == *Dockerfile* ]]; then
    # resolve ARG defaults declared in the same Dockerfile
    declare -A ARGS=()
    while IFS='=' read -r k v; do ARGS[$k]="$v"; done < <(sed -nE 's/^ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=("?)([^"]*)\2[[:space:]]*$/\1=\3/p' "$f")
    while IFS=: read -r ln line; do
      ref=$(awk '{print $2}' <<< "$line")
      for k in "${!ARGS[@]}"; do ref="${ref//\$\{$k\}/${ARGS[$k]}}"; ref="${ref//\$$k/${ARGS[$k]}}"; done
      case "$ref" in [a-z]*-build|build|go-build|rust-build|front_build|api_build) continue ;; esac
      emit IMAGE "$(classify_ref "$ref")" "$f:$ln" "$ref"
    done < <(grep -n -E '^[[:space:]]*FROM[[:space:]]' "$f" || true)
    unset ARGS
  else
    while IFS=: read -r ln line; do
      ref=$(sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/["'\'']//g; s/[[:space:]]+#.*$//; s/[[:space:]]*$//' <<< "$line")
      ref=$(sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}/\1/g' <<< "$ref")
      emit IMAGE "$(classify_ref "$ref")" "$f:$ln" "$ref"
    done < <(grep -n -E '^[[:space:]]*image:[[:space:]]' "$f" || true)
  fi
done < <(git ls-files -- 'docker-compose*.yml' 'deploy/*.yml' 'examples/*/compose.yml' '**/Dockerfile*' 'Dockerfile*' '.github/workflows/*' | sort -u)

while IFS=: read -r f ln line; do
  ref=$(grep -oE 'docker run [^|&;>]*' <<< "$line" | awk '{for(i=3;i<=NF;i++){ if ($i ~ /^-/) { if ($i ~ /^(-p|-v|-e|--name|--network|--add-host)$/) i++; continue } print $i; exit }}')
  [ -n "$ref" ] && emit IMAGE "$(classify_ref "$ref")" "$f:$ln" "$ref (docker run)"
done < <(git ls-files -z -- '*.sh' ':!.claude' | xargs -0 grep -n -E 'docker run ' 2>/dev/null | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' || true)

[ "$SUMMARY_ONLY" = 1 ] || { echo; echo "== TOOL: floating tool versions and pipe-to-shell installers =="; }
SCOPE=( $(git ls-files -- '**/Dockerfile*' 'Dockerfile*' '.github/workflows/*' '*.sh' 'docker/*' 'deploy/*' 'extra/*' 'scripts/*' ':!.claude' | sort -u) )
while IFS=: read -r f ln line; do emit TOOL AT-LATEST "$f:$ln" "$(grep -oE '[A-Za-z0-9_./@-]*@latest' <<< "$line" | head -1)"; done \
  < <(grep -n -E '@latest\b' "${SCOPE[@]}" 2>/dev/null | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' || true)
while IFS=: read -r f ln line; do emit TOOL VERSION-LATEST "$f:$ln" "version: latest"; done \
  < <(grep -n -E '^[[:space:]]*version:[[:space:]]*latest[[:space:]]*$' "${SCOPE[@]}" 2>/dev/null || true)
while IFS=: read -r f ln line; do emit TOOL CURL-PIPE-SH "$f:$ln" "$(grep -oE 'https?://[^ |]+' <<< "$line" | head -1) | sh"; done \
  < <(grep -n -E '(curl|wget)[^|#]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z)?sh\b' "${SCOPE[@]}" 2>/dev/null || true)
while IFS=: read -r f ln line; do emit TOOL GO-INSTALL-PARTIAL "$f:$ln" "$(grep -oE '[A-Za-z0-9_./-]+@v[0-9]+(\.[0-9]+)?\b' <<< "$line" | head -1)"; done \
  < <(grep -n -E 'go install [^ ]+@v[0-9]+(\.[0-9]+)?([[:space:]]|$)' "${SCOPE[@]}" 2>/dev/null || true)

[ "$SUMMARY_ONLY" = 1 ] || { echo; echo "== ACTION: GitHub Actions uses: refs =="; }
while IFS=: read -r f ln line; do
  ref=$(sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//; s/["'\'']//g; s/[[:space:]]+#.*$//; s/[[:space:]]*$//' <<< "$line")
  case "$ref" in
    ./*) cls=LOCAL ;;
    *@*) r="${ref##*@}"
         if [[ "$r" =~ ^[0-9a-f]{40}$ ]]; then cls=SHA
         elif [[ "$r" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then cls=EXACT-TAG
         else cls=MAJOR-TAG; fi ;;
    *) cls=MAJOR-TAG ;;
  esac
  emit ACTION "$cls" "$f:$ln" "$ref"
done < <(git ls-files -z -- '.github/workflows/*' '.github/actions/*' | xargs -0 grep -n -E '^[[:space:]]*-?[[:space:]]*uses:' 2>/dev/null || true)

[ "$SUMMARY_ONLY" = 1 ] || { echo; echo "== CLONE: source fetched by mutable ref =="; }
while IFS= read -r f; do
  while IFS=: read -r ln line; do
    co=$(grep -n -E 'git checkout' "$f" | awk -F: -v l="$ln" '$1>=l && $1<=l+4 {sub(/^[0-9]+:/,""); print; exit}')
    ref=$(grep -oE 'git checkout [^ &;]+' <<< "$co" | awk '{print $3}')
    if [[ "$ref" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
      def=$(sed -nE "s/^ARG[[:space:]]+${BASH_REMATCH[1]}=\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$f" | head -1)
      ref="$ref(ARG default ${def:-none})"
    fi
    emit CLONE GIT-CLONE-TAG "$f:$ln" "$(grep -oE 'https?://[^ ]+' <<< "$line" | head -1) checkout=${ref:-?}"
  done < <(grep -n -E 'git clone' "$f" || true)
done < <(git ls-files -- '**/Dockerfile*' 'Dockerfile*' 'docker/*' '*.sh' ':!.claude' | sort -u)
while IFS=$'\t' read -r f ln repo ref; do
  [ -n "$ln" ] || continue
  case "$repo" in *'${{'*) continue ;; esac   # parameterized by the caller: not a pin
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then continue; fi
  emit CLONE CHECKOUT-REF "$f:$ln" "repository=$repo ref=${ref:-default-branch}"
done < <(git ls-files -- '.github/workflows/*' | sort | while IFS= read -r f; do
  awk -v f="$f" '
    function out() { if (inco && repo!="") print f "\t" start "\t" repo "\t" ref; inco=0 }
    /uses:[[:space:]]*actions\/checkout@/ {out(); inco=1; repo=""; ref=""; start=NR; next}
    inco && /^[[:space:]]*repository:/ {repo=$0; sub(/^[[:space:]]*repository:[[:space:]]*/,"",repo)}
    inco && /^[[:space:]]*ref:/ {ref=$0; sub(/^[[:space:]]*ref:[[:space:]]*/,"",ref)}
    inco && (/^[[:space:]]*- / || /^[[:space:]]*$/) {out()}
    END {out()}
  ' "$f"; done)

[ "$SUMMARY_ONLY" = 1 ] || { echo; echo "== VENDOR: committed binaries =="; }
while IFS= read -r j; do
  d=$(dirname "$j"); b=$(basename "$j")
  if git ls-files -- "$d/$b.sha1" "$d/$b.sha256" "$d/$b.asc" "$d/SHA256SUMS" "$d/checksums.txt" | grep -q .; then
    emit VENDOR JAR-WITH-CHECKSUM "$j"
  else
    emit VENDOR JAR-NO-CHECKSUM "$j"
  fi
done < <(git ls-files -- '*.jar' | sort)

[ "$SUMMARY_ONLY" = 1 ] || { echo; echo "== SOCK: docker.sock mounts / use =="; }
while IFS=: read -r f ln line; do emit SOCK DOCKER-SOCK "$f:$ln" ""; done \
  < <(git ls-files -z -- '*.yml' '*.yaml' '*.sh' 'docker/*' '*.md' ':!.claude' | xargs -0 grep -n 'docker\.sock' 2>/dev/null || true)

echo
for k in $(printf '%s\n' "${!COUNT[@]}" | sort); do echo "count $k ${COUNT[$k]}"; done
latest=$(( ${COUNT["IMAGE:LATEST"]:-0} + ${COUNT["IMAGE:NO-TAG"]:-0} + ${COUNT["TOOL:AT-LATEST"]:-0} + ${COUNT["TOOL:VERSION-LATEST"]:-0} ))
echo "SUMMARY unpinned-scan: images_digest=${COUNT["IMAGE:DIGEST"]:-0} images_latest=${COUNT["IMAGE:LATEST"]:-0} images_major_or_minor=$(( ${COUNT["IMAGE:MAJOR"]:-0} + ${COUNT["IMAGE:MINOR"]:-0} )) actions_sha=${COUNT["ACTION:SHA"]:-0} actions_mutable=$(( ${COUNT["ACTION:MAJOR-TAG"]:-0} + ${COUNT["ACTION:EXACT-TAG"]:-0} )) tools_latest=$(( ${COUNT["TOOL:AT-LATEST"]:-0} + ${COUNT["TOOL:VERSION-LATEST"]:-0} )) clones=$(( ${COUNT["CLONE:GIT-CLONE-TAG"]:-0} + ${COUNT["CLONE:CHECKOUT-REF"]:-0} )) jars_no_checksum=${COUNT["VENDOR:JAR-NO-CHECKSUM"]:-0} docker_sock=${COUNT["SOCK:DOCKER-SOCK"]:-0}"
if [ "$FAIL_LATEST" = 1 ] && [ "$latest" -gt 0 ]; then exit 1; fi
exit 0
