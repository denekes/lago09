#!/usr/bin/env bash
# sidekiq-web-exposure.sh - is Sidekiq Web (/sidekiq) on, reachable and unauthenticated, per plane?
#
# Usage: sidekiq-web-exposure.sh [--repo DIR] [--api DIR]
#   --api DIR  lago-api checkout to read (default: pinned-checkout.sh api, i.e. the gitlink SHA)
#
# Output (tab-separated):
#   PLANE <plane> <file:line|-> default=<value|unset> on=<yes|no> reach=<how the API port is exposed>
#   API   <check> <$API-relative file:line|-> <detail>
#   VERDICT <plane> <EXPOSED-UNAUTH|OFF|DEV-ONLY> <url pattern>
#   SUMMARY ...
# Semantics (read from the pinned lago-api, not assumed): routes.rb mounts Sidekiq::Web only when
#   ENV["LAGO_SIDEKIQ_WEB"] == "true" (exact string). An unset or empty value means OFF.
# Read-only. Exit codes: 0 done; 2 usage; 3 lago-api checkout unavailable (plane rows still printed).
set -euo pipefail

REPO=""; API=""
need() { [ -n "$2" ] || { echo "$1" >&2; exit 2; }; }   # missing option value = usage (exit 2)
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "--repo needs a directory" "${2:-}"; REPO="$2"; shift 2 ;;
    --api) need "--api needs a lago-api directory" "${2:-}"; API="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo; use --repo" >&2; exit 2; }
cd "$REPO"

# value of LAGO_SIDEKIQ_WEB as the plane would resolve it with an empty .env
plane_default() { # file -> "line<TAB>value"
  local f="$1" hit
  hit=$(grep -n -E 'LAGO_SIDEKIQ_WEB' "$f" 2>/dev/null | grep -v -E '^[0-9]+:[[:space:]]*#' | head -1 || true)
  [ -n "$hit" ] || { printf -- '-\tunset\n'; return; }
  local ln="${hit%%:*}" rest="${hit#*:}" val
  if [[ "$rest" =~ \$\{LAGO_SIDEKIQ_WEB:-([^}]*)\} ]]; then val="${BASH_REMATCH[1]}"
  elif [[ "$rest" =~ \$\{LAGO_SIDEKIQ_WEB\} ]]; then val=""
  else val=$(sed -E 's/^[^=:]*[=:][[:space:]]*//; s/["'\'' ]//g' <<< "$rest"); fi
  printf '%s\t%s\n' "$ln" "${val:-<empty>}"
}

# how the API container port 3000 is reachable in a compose file
api_reach() {
  local f="$1" pub tr
  pub=$(awk '/^  api:[[:space:]]*$/ {a=1; next} a && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {a=0}
             a && /:3000[[:space:]"]*$/ && /^[[:space:]]*-/ {print NR; exit}' "$f")
  tr=$(grep -n -E 'traefik\.http\.routers\.[a-z_-]+\.rule=.*(PathPrefix\(`/api/`\)|Host\(`api\.lago\.dev`\))' "$f" | head -1 | cut -d: -f1 || true)
  if [ -n "$pub" ]; then echo "host-port:$f:$pub"
  elif [ -n "$tr" ]; then echo "traefik:$f:$tr"
  else echo "not-published"; fi
}

declare -A URL=(
  [docker-compose.yml]='http://<host>:${API_PORT:-3000}/sidekiq'
  [deploy/docker-compose.local.yml]='http://<host>:${API_PORT:-3000}/sidekiq'
  [deploy/docker-compose.light.yml]='https://<LAGO_DOMAIN>/api/sidekiq (Traefik strips /api)'
  [deploy/docker-compose.production.yml]='https://<LAGO_DOMAIN>/api/sidekiq (Traefik strips /api)'
  [docker-compose.dev.yml]='https://api.lago.dev/sidekiq'
)
EXPOSED=0
echo "== Planes: LAGO_SIDEKIQ_WEB default and API reachability =="
for f in docker-compose.yml deploy/docker-compose.local.yml deploy/docker-compose.light.yml deploy/docker-compose.production.yml docker-compose.dev.yml; do
  [ -f "$f" ] || continue
  src="$f"
  IFS=$'\t' read -r ln val < <(plane_default "$f")
  if [ "$f" = docker-compose.dev.yml ]; then src=.env.development.default; IFS=$'\t' read -r ln val < <(plane_default "$src"); fi
  on=no; [ "$val" = true ] && on=yes
  reach=$(api_reach "$f")
  printf 'PLANE\t%s\t%s:%s\tdefault=%s\ton=%s\treach=%s\n' "$f" "$src" "$ln" "$val" "$on" "$reach"
  if [ "$on" = yes ] && [ "$reach" != not-published ]; then
    if [ "$f" = docker-compose.dev.yml ]; then v=DEV-ONLY; else v=EXPOSED-UNAUTH; EXPOSED=$((EXPOSED+1)); fi
  else v=OFF; fi
  VERDICTS+=("$(printf 'VERDICT\t%s\t%s\t%s' "$f" "$v" "${URL[$f]}")")
done
# single image: runner.sh default map
IFS=$'\t' read -r ln val < <(plane_default docker/runner.sh)
printf 'PLANE\t%s\t%s:%s\tdefault=%s\ton=%s\treach=%s\n' "docker/ (getlago/lago)" docker/runner.sh "$ln" "$val" "$([ "$val" = true ] && echo yes || echo no)" "docker run -p 3000:3000 (docker/README.md)"
VERDICTS+=("$(printf 'VERDICT\t%s\t%s\t%s' "docker/ (getlago/lago)" "$([ "$val" = true ] && echo EXPOSED-UNAUTH || echo OFF)" 'http://<host>:3000/sidekiq only if LAGO_SIDEKIQ_WEB=true is passed')")

echo
echo "== lago-api (read-only) =="
API_OK=1
if [ -z "$API" ]; then
  PC="$REPO/.claude/skills/research-methodology/scripts/pinned-checkout.sh"
  API=$("$PC" api 2>/dev/null) || API=""
fi
if [ -z "$API" ] || [ ! -f "$API/config/routes.rb" ]; then
  echo "API	unavailable	-	no lago-api checkout (run pinned-checkout.sh api or pass --api)"; API_OK=0
else
  sha=$(git -C "$API" rev-parse --short=7 HEAD 2>/dev/null || echo "?")
  echo "API	checkout	-	lago-api@$sha"
  grep -n -E 'LAGO_SIDEKIQ_WEB|Sidekiq::Web|Sidekiq::Prometheus::Exporter|Yabeda::Prometheus::Exporter|Karafka::Web::App' "$API/config/routes.rb" \
    | while IFS=: read -r l txt; do printf 'API\tmount\tconfig/routes.rb:%s\t%s\n' "$l" "$(sed -E 's/^[[:space:]]+//' <<< "$txt")"; done
  grep -n -E 'Sidekiq::Web\.use|LAGO_SIDEKIQ_WEB' "$API/config/initializers/sidekiq.rb" 2>/dev/null \
    | while IFS=: read -r l txt; do printf 'API\tmiddleware\tconfig/initializers/sidekiq.rb:%s\t%s\n' "$l" "$(sed -E 's/^[[:space:]]+//' <<< "$txt")"; done
  auth=$( { grep -rn -E 'Rack::Auth::Basic|Sidekiq::Web\.use[^#]*Auth|authenticate[^#]*Sidekiq|constraints[^#]*Sidekiq|Sidekiq::Web\.use[^#]*Warden' \
           "$API/config" "$API/app" "$API/lib" 2>/dev/null || true; } | wc -l)
  printf 'API\tauth-middleware-hits\t-\t%s (0 = no authentication in front of Sidekiq::Web inside lago-api)\n' "$auth"
fi

echo
printf '%s\n' "${VERDICTS[@]}"
echo
echo "SUMMARY sidekiq-web-exposure: planes_exposed_unauth=$EXPOSED api_auth_hits=${auth:-n/a} (exposure is inferred from config; not exercised at runtime here)"
[ "$API_OK" = 1 ] || exit 3
exit 0
