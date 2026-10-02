#!/usr/bin/env bash
# templates-check.sh — prove the validation-and-qa test templates still compile and pass at HEAD.
#
# Usage: templates-check.sh [-v] [-race] [--keep]
#   Overlays every templates/*_test.go.tmpl into its events-processor package with
#   `go test -overlay` (the repo is never written, change-control N10) and runs
#   `go test -count=1 -run '^TestTemplate' <pkg>`. -v and -race are passed to go test.
#   --keep keeps the temp dir (overlay JSON) and prints its path.
# Package mapping (from the template's `package` clause):
#   events_processor -> processors/events_processor   models -> models   cache -> cache
#   kafka -> config/kafka
# Needs: the CGO env from build-and-env/scripts/ep-env.sh (sourced here; the events_processor
#   package links libexpression_go). No Postgres needed.
# Exit: 0 all templates pass; 1 a template failed to compile or a test failed; 2 setup error.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill="$(dirname "$here")"
repo="$(git -C "$here" rev-parse --show-toplevel)"
ep="$repo/events-processor"

gotest_flags=()
keep=0
for a in "$@"; do
  case "$a" in
    -v|-race) gotest_flags+=("$a") ;;
    --keep) keep=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "templates-check: unknown argument: $a" >&2; exit 2 ;;
  esac
done

# shellcheck source=/dev/null
source "$repo/.claude/skills/build-and-env/scripts/ep-env.sh" || { echo "templates-check: ep-env.sh failed" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/vqa-templates.XXXXXX")"
if [ "$keep" = 0 ]; then trap 'rm -rf "$tmp"' EXIT; else echo "templates-check: keeping $tmp" >&2; fi

declare -A pkgdir=( [events_processor]=processors/events_processor [models]=models [cache]=cache [kafka]=config/kafka )
declare -A pkgs_used=()
json='{"Replace":{'
sep=''
shopt -s nullglob
tmpls=("$skill"/templates/*_test.go.tmpl)
[ ${#tmpls[@]} -gt 0 ] || { echo "templates-check: no templates found in $skill/templates" >&2; exit 2; }
for f in "${tmpls[@]}"; do
  pkg="$(awk '/^package / { print $2; exit }' "$f")"
  dir="${pkgdir[$pkg]:-}"
  [ -n "$dir" ] || { echo "templates-check: $f: unknown package '$pkg'" >&2; exit 2; }
  base="$(basename "$f" .tmpl)"
  json+="$sep\"$ep/$dir/zz_vqa_$base\":\"$f\""
  sep=','
  pkgs_used["./$dir/"]=1
  echo "templates-check: $(basename "$f") -> events-processor/$dir/zz_vqa_$base" >&2
done
json+='}}'
printf '%s\n' "$json" > "$tmp/overlay.json"

cd "$ep"
porcelain_before="$(git -C "$repo" status --porcelain --ignored -- events-processor)"
set +e
go test -count=1 "${gotest_flags[@]}" -overlay="$tmp/overlay.json" -run '^TestTemplate' "${!pkgs_used[@]}"
rc=$?
set -e
if [ $rc -eq 0 ]; then
  echo "templates-check: OK all templates pass (${#tmpls[@]} files)"
else
  echo "templates-check: FAIL (go test exit $rc) - a template no longer matches the code at HEAD" >&2
  rc=1
fi
porcelain="$(git -C "$repo" status --porcelain --ignored -- events-processor)"
[ "$porcelain" = "$porcelain_before" ] || echo "templates-check: WARNING events-processor/ changed during the run (before: ${porcelain_before:-clean}; after: $porcelain)" >&2
exit $rc
