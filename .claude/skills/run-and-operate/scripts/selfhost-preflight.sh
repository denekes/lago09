#!/usr/bin/env bash
# selfhost-preflight.sh — read-only audit of a self-host .env BEFORE `docker compose up`.
#
# Checks the .env you will feed to the root docker-compose.yml or a deploy/ variant:
#   - file hygiene, parsed the way docker compose v2 reads --env-file: KEY=VALUE / comment /
#     blank, and '...' or "..." values that span several lines (compose joins them with
#     newlines). Catches deploy.sh's polluted ".env" ("✅ ... is already set" lines, which compose
#     rejects with "unexpected character"), unterminated quotes, and UNQUOTED values wrapped over
#     several lines (compose silently reads the extra lines as bare variable names)
#   - placeholder or missing secrets that the compose files silently default to
#     (SECRET_KEY_BASE, LAGO_ENCRYPTION_*, POSTGRES_PASSWORD=changeme, S3 azerty123456,
#      PORTAINER_PASSWORD=changeme)
#   - LAGO_RSA_PRIVATE_KEY format: base64 (openssl base64 -A, one line) of a PEM RSA private key
#     that openssl can parse. lago-api config/initializers/rsa_keys.rb: Base64.decode64 (:10),
#     abort "Private key is blank" (:13-15), OpenSSL::PKey::RSA.new (:17). Verified 2026-10-01 with
#     ruby on the value compose passes: one-line base64 OK; base64 wrapped INSIDE quotes OK
#     (decode64 ignores newlines; WARN only); raw PEM and unquoted wrapped base64 raise
#     OpenSSL::PKey::RSAError "Neither PUB key nor PRIV key"; empty -> "Private key is blank"
#   - variant specifics: LAGO_DOMAIN / LAGO_ACME_EMAIL (light, production), Portainer creds
#     (production), seeding vars when LAGO_CREATE_ORG=true
#   - exposure defaults worth knowing (unauthenticated /sidekiq, Segment telemetry, Redis without
#     password on a published port); details live in the security-and-supply-chain skill
#   - `docker compose --env-file <file> config --quiet` for the chosen variant (no daemon needed)
# Secret VALUES are never printed (change-control N11): only names, lengths and verdicts.
#
# Usage:  selfhost-preflight.sh [--variant root|local|light|production] ENV_FILE
#         (default variant: root = docker-compose.yml at the repo root)
# Exit:   number of FAIL lines, capped at 63 (0 = no blocker found); 64 = usage error.
# Needs:  bash, base64, openssl, git; docker compose v2 optional (compose check is skipped without it).
set -uo pipefail

variant=root; envf=""
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) variant="${2:-}"; shift ;;
    --variant=*) variant="${1#*=}" ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 64 ;;
    *) envf="$1" ;;
  esac
  shift
done
case "$variant" in root|local|light|production) ;; *) echo "bad --variant: $variant" >&2; exit 64 ;; esac
[ -n "$envf" ] && [ -f "$envf" ] || { echo "usage: $0 [--variant root|local|light|production] ENV_FILE" >&2; exit 64; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || true)"
fails=0
ok()   { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails+1)); }
info() { printf 'INFO  %s\n' "$*"; }
skip() { printf 'SKIP  %s\n' "$*"; }

# ---- parse without sourcing (compose v2 --env-file rules) ---------------------------------
declare -A V=() ML=() CONT=()   # V: values; ML: physical lines of a quoted multi-line value; CONT: unquoted wrap seen
mapfile -t L < "$envf"
prev_key=""; cont_key=""; cont_from=0; cont_n=0
flush_cont() {
  if [ "$cont_n" -gt 0 ]; then
    fail "lines $cont_from-$((cont_from+cont_n-1)): $cont_n line(s) look like an UNQUOTED continuation of $cont_key; compose reads them as bare variable names and keeps only the first line of $cont_key (for the RSA key use 'openssl base64 -A')"
    CONT[$cont_key]=1; cont_n=0
  fi
}
i=0
while [ "$i" -lt "${#L[@]}" ]; do
  line="${L[$i]%$'\r'}"; n=$((i+1)); i=$((i+1))
  case "$line" in ''|'#'*|[[:space:]]'#'*) flush_cont; prev_key=""; continue ;; esac
  l="${line#export }"
  if [[ "$l" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    flush_cont
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; q="${v:0:1}"
    if [[ "$v" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]] || [[ "$v" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      v="${BASH_REMATCH[1]}"   # quoted on one line, optional trailing comment
    elif { [ "$q" = '"' ] || [ "$q" = "'" ]; } && [[ "${v:1}" != *"$q"* ]]; then
      # opening quote with no closing quote on this line: compose continues the value on the
      # next lines until a line ends with the same quote
      acc="${v:1}"; closed=0
      while [ "$i" -lt "${#L[@]}" ]; do
        nl="${L[$i]%$'\r'}"; i=$((i+1))
        if [ -n "$nl" ] && [ "${nl: -1}" = "$q" ]; then acc+=$'\n'"${nl%?}"; closed=1; break; fi
        acc+=$'\n'"$nl"
      done
      if [ "$closed" = 0 ]; then
        fail "line $n: $k opens a $q-quoted value that is never closed; compose rejects the file ('unterminated quoted value')"
      fi
      ML[$k]=$((i - n + 1)); v="$acc"
    elif [[ "$v" =~ ^\"(.*)\"$ ]] || [[ "$v" =~ ^\'(.*)\'$ ]]; then
      v="${BASH_REMATCH[1]}"
    fi
    V[$k]="$v"; prev_key="$k"
  elif [ -n "$prev_key" ] && { [[ "$line" =~ ^[A-Za-z0-9+/=]{16,}$ ]] || { [ "$cont_n" -gt 0 ] && [[ "$line" =~ ^[A-Za-z0-9+/=]+$ ]]; }; }; then
    [ "$cont_n" -eq 0 ] && { cont_key="$prev_key"; cont_from=$n; }
    cont_n=$((cont_n+1))
  else
    flush_cont
    bad="$(printf '%s' "$line" | LC_ALL=C tr -d '[:print:]' | wc -c)"
    fail "line $n: not KEY=VALUE${bad:+ (contains $bad non-printable/non-ASCII bytes)}; compose rejects such lines (e.g. 'unexpected character', 'key cannot contain a space'). deploy.sh writes them (deploy/deploy.sh:295)"
  fi
done
flush_cont
info "variant=$variant file=$envf: ${#V[@]} assignment(s) parsed"

has()  { [ -n "${V[$1]+x}" ] && [ -n "${V[$1]}" ]; }
len()  { printf '%s' "${V[$1]}" | wc -c | tr -d ' '; }

# ---- secrets the compose files default to placeholders -----------------------------------
secret_check() { # name placeholder-regex why
  local k="$1" re="$2" why="$3"
  if ! has "$k"; then fail "$k not set: compose falls back to a public placeholder ($why)"
  elif [[ "${V[$k]}" =~ $re ]]; then fail "$k is still the placeholder ($why)"
  else ok "$k set (length $(len "$k"); value not shown)"; fi
}
secret_check SECRET_KEY_BASE '^your-secret-key-base' "Rails session/JWT signing; e.g. openssl rand -hex 64"
for k in LAGO_ENCRYPTION_PRIMARY_KEY LAGO_ENCRYPTION_DETERMINISTIC_KEY LAGO_ENCRYPTION_KEY_DERIVATION_SALT; do
  secret_check "$k" '^your-encr' "ActiveRecord encryption; e.g. openssl rand -hex 32; NEVER change after data exists"
done
if has SECRET_KEY_BASE && [ "$(len SECRET_KEY_BASE)" -lt 32 ]; then warn "SECRET_KEY_BASE is short ($(len SECRET_KEY_BASE) chars); 'openssl rand -hex 64' gives 128"; fi

external_pg=0; has POSTGRES_HOST && [ "${V[POSTGRES_HOST]}" != db ] && external_pg=1
if [ "$external_pg" = 1 ]; then
  info "POSTGRES_HOST is external (value not shown): bundled db not used (deploy profiles all-no-pg / all-no-db)"
fi
if ! has POSTGRES_PASSWORD || [ "${V[POSTGRES_PASSWORD]}" = changeme ]; then
  fail "POSTGRES_PASSWORD unset or 'changeme' (default in every self-host compose file; the db port \${POSTGRES_PORT:-5432} is published on the host)"
else ok "POSTGRES_PASSWORD set (length $(len POSTGRES_PASSWORD))"; fi

if [ "${V[LAGO_USE_AWS_S3]:-false}" = true ]; then
  for k in LAGO_AWS_S3_ACCESS_KEY_ID LAGO_AWS_S3_SECRET_ACCESS_KEY; do
    if ! has "$k" || [ "${V[$k]}" = azerty123456 ]; then fail "$k unset or the 'azerty123456' placeholder while LAGO_USE_AWS_S3=true"; else ok "$k set"; fi
  done
  has LAGO_AWS_S3_BUCKET || warn "LAGO_AWS_S3_BUCKET unset: compose default is 'bucket'"
else
  info "LAGO_USE_AWS_S3 not 'true': files go to the lago_storage_data volume (/app/storage)"
fi

# ---- RSA key ----------------------------------------------------------------------------
if has LAGO_RSA_PRIVATE_KEY; then
  key="${V[LAGO_RSA_PRIVATE_KEY]}"; key1="${key//$'\n'/}"
  if [[ "$key" == -----BEGIN* ]]; then
    fail "LAGO_RSA_PRIVATE_KEY is a raw PEM: lago-api Base64-decodes it (config/initializers/rsa_keys.rb:10) and OpenSSL then raises 'Neither PUB key nor PRIV key' (:17). Use base64 of the PEM on one line: openssl genrsa 2048 | openssl base64 -A"
  elif [ -n "${CONT[LAGO_RSA_PRIVATE_KEY]:-}" ]; then
    fail "LAGO_RSA_PRIVATE_KEY is wrapped over several UNQUOTED lines: compose passes only the first line and lago-api raises 'Neither PUB key nor PRIV key'. Regenerate with: openssl genrsa 2048 | openssl base64 -A"
  elif [[ "$key1" =~ [^A-Za-z0-9+/=] ]]; then
    fail "LAGO_RSA_PRIVATE_KEY contains characters outside the base64 alphabet (spaces, stray quotes?)"
  elif ! command -v openssl >/dev/null 2>&1; then
    skip "openssl missing: cannot decode/parse LAGO_RSA_PRIVATE_KEY"
  else
    pem="$(printf '%s' "$key1" | base64 -d 2>/dev/null || true)"
    if [[ "$pem" != -----BEGIN* ]]; then
      fail "LAGO_RSA_PRIVATE_KEY does not base64-decode to a PEM block"
    elif bits="$(printf '%s\n' "$pem" | openssl rsa -noout -text 2>/dev/null | sed -nE '1s/.*\(([0-9]+) bit.*/\1/p')" && [ -n "$bits" ]; then
      if [ -n "${ML[LAGO_RSA_PRIVATE_KEY]:-}" ]; then
        warn "LAGO_RSA_PRIVATE_KEY spans ${ML[LAGO_RSA_PRIVATE_KEY]} lines inside quotes: compose v2 joins them and lago-api's Base64.decode64 ignores the newlines, so it works, but line-based tools (deploy.sh's 'grep | xargs', shell 'source') break it; prefer one line (openssl base64 -A)"
      fi
      ok "LAGO_RSA_PRIVATE_KEY: base64 -> PEM RSA private key, $bits bit (value not shown)"
    else
      fail "LAGO_RSA_PRIVATE_KEY decodes to a PEM that openssl cannot parse as an RSA private key"
    fi
  fi
else
  if [ "$variant" = root ]; then
    fail "LAGO_RSA_PRIVATE_KEY not set: root docker-compose.yml has no rsa-keys service, so api/worker/clock abort ('Private key is blank'). Add: echo \"LAGO_RSA_PRIVATE_KEY=\\\"\$(openssl genrsa 2048 | openssl base64 -A)\\\"\" >> $envf"
  else
    info "LAGO_RSA_PRIVATE_KEY not set: deploy/$variant relies on the rsa-keys service (profiles all, all-no-pg, all-no-redis, all-no-db) writing config/keys/private.pem into lago_rsa_data; with --profile all-no-keys you must set it"
  fi
fi

# ---- variant specifics ------------------------------------------------------------------
if [ "$variant" = light ] || [ "$variant" = production ]; then
  if ! has LAGO_DOMAIN || [ "${V[LAGO_DOMAIN]}" = domain.tld ]; then fail "LAGO_DOMAIN unset or 'domain.tld': Traefik Host() rules and LAGO_API_URL/LAGO_FRONT_URL are built from it"; else ok "LAGO_DOMAIN set"; fi
  if ! has LAGO_ACME_EMAIL || [[ "${V[LAGO_ACME_EMAIL]}" =~ ^(your_email@example\.com|email@domain\.tld)$ ]]; then warn "LAGO_ACME_EMAIL unset or example value"; else ok "LAGO_ACME_EMAIL set"; fi
  warn "deploy/docker-compose.$variant.yml hard-codes the Let's Encrypt STAGING CA (caServer acme-staging-v02): browsers will not trust the certificate"
  warn "deploy/docker-compose.$variant.yml exposes the Traefik dashboard (--api.insecure=true) on host port 8080"
fi
if [ "$variant" = production ]; then
  if ! has PORTAINER_PASSWORD || [ "${V[PORTAINER_PASSWORD]}" = changeme ]; then fail "PORTAINER_PASSWORD unset or 'changeme' (portainer is routed at https://\$LAGO_DOMAIN/portainer)"; else ok "PORTAINER_PASSWORD set"; fi
  warn "deploy/docker-compose.production.yml: pdf-worker runs ./scripts/start.pdf.worker.sh which does not exist in lago-api (only start.pdfs.worker.sh), and no worker sets SIDEKIQ_*=true, so the dedicated workers idle"
fi
if [ "$variant" != root ]; then
  warn "deploy/ variants pin getlago/api and getlago/front v1.27.1 (root docker-compose.yml is current); plain postgres:15-alpine, so no pg_partman"
fi

if [ "${V[LAGO_CREATE_ORG]:-false}" = true ]; then
  for k in LAGO_ORG_USER_EMAIL LAGO_ORG_USER_PASSWORD LAGO_ORG_NAME; do
    has "$k" && ok "$k set (LAGO_CREATE_ORG=true)" || fail "$k required when LAGO_CREATE_ORG=true (lago-api signup:seed_organization raises without it)"
  done
  has LAGO_ORG_API_KEY && info "LAGO_ORG_API_KEY set: the seeded org gets this exact API key (value not shown)"
fi

# ---- exposure defaults ------------------------------------------------------------------
if [ "${V[LAGO_SIDEKIQ_WEB]:-true}" = true ]; then
  warn "LAGO_SIDEKIQ_WEB defaults to true: Sidekiq Web is mounted at /sidekiq WITHOUT authentication (lago-api config/routes.rb:4-6); set LAGO_SIDEKIQ_WEB=false unless protected upstream (see security-and-supply-chain)"
else ok "LAGO_SIDEKIQ_WEB=${V[LAGO_SIDEKIQ_WEB]}"; fi
if [ "${V[LAGO_DISABLE_SEGMENT]:-}" != true ]; then warn "LAGO_DISABLE_SEGMENT is not 'true': Segment telemetry stays on (lago-api compares == \"true\")"; else ok "LAGO_DISABLE_SEGMENT=true"; fi
if has REDIS_PASSWORD; then
  warn "REDIS_PASSWORD set: the bundled redis service is started without --requirepass, so only use it with an external Redis (inferred)"
else
  info "REDIS_PASSWORD unset: bundled Redis runs without a password and its port \${REDIS_PORT:-6379} is published on the host"
fi
if [ "$variant" = root ] || [ "$variant" = local ]; then
  has LAGO_API_URL || info "LAGO_API_URL unset: defaults to http://localhost:3000 (UI works only from a browser on the same host)"
  has LAGO_FRONT_URL || info "LAGO_FRONT_URL unset: defaults to http://localhost (CORS origin)"
fi

# ---- compose parse with this env file -----------------------------------------------------
case "$variant" in root) cf="docker-compose.yml" ;; *) cf="deploy/docker-compose.$variant.yml" ;; esac
if [ -n "$repo" ] && [ -f "$repo/$cf" ] && command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  absf="$(cd "$(dirname "$envf")" && pwd)/$(basename "$envf")"
  if out="$(cd "$repo" && env -i PATH="$PATH" HOME="$HOME" docker compose --env-file "$absf" -f "$cf" config --quiet 2>&1)"; then
    nw="$(printf '%s\n' "$out" | grep -c 'is not set' || true)"
    ok "docker compose --env-file <file> -f $cf config: parses ($nw unset-variable warnings)"
  else
    # compose quotes the offending value in its error: keep only "line N: <reason>" and redact base64-ish runs
    msg="$(printf '%s\n' "$out" | grep -v 'is not set' | head -1 | sed -E 's/.*(line [0-9]+: [^"]*).*/\1/; s/[A-Za-z0-9+\/=]{24,}/<redacted>/g')"
    fail "docker compose -f $cf rejects this env file: $msg"
  fi
else
  skip "compose parse: docker compose v2 or $cf not available"
fi

echo "selfhost-preflight: $fails FAIL(s)"
[ "$fails" -gt 63 ] && exit 63
exit "$fails"
