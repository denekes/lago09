#!/usr/bin/env bash
# dev-preflight.sh — read-only checks BEFORE `docker compose -f docker-compose.dev.yml up`.
#
# One line per check: OK / WARN / FAIL / INFO / SKIP. Covers the traps that make the dev stack
# fail on first start: Docker daemon, compose validity, empty api/ front/ submodules (build
# contexts), mkcert certificates for Traefik, /etc/hosts vs the Host() rules in the compose file,
# api/.env + api/config/master.key (docs/dev_environment.md steps), the EXTERNAL volume
# lago_front_pnpm_store, host ports already taken, .env.development overrides that do not do
# what they look like, and the `lago` alias that non-interactive shells never see.
#
# Usage:   dev-preflight.sh            (run from anywhere inside the repo)
# Exit:    number of FAIL lines (0 = nothing blocks `up`; WARNs may still bite).
# Needs:   bash, git, getent; optional: docker (+compose v2), openssl. Writes nothing.
# No `set -e` on purpose: every check runs even when an earlier one fails.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
ok()   { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails+1)); }
info() { printf 'INFO  %s\n' "$*"; }
skip() { printf 'SKIP  %s\n' "$*"; }

repo="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)" || { fail "not inside a git checkout"; exit 1; }
dcf="$repo/docker-compose.dev.yml"
[ -f "$dcf" ] || { fail "docker-compose.dev.yml not found at repo root"; exit "$fails"; }
info "repo $repo (HEAD $(git -C "$repo" rev-parse --short HEAD 2>/dev/null)); compose file docker-compose.dev.yml (project lago_dev)"

# 1. Docker CLI, compose v2, daemon
daemon=0
if ! command -v docker >/dev/null 2>&1; then
  fail "docker CLI not installed"
else
  if v="$(docker compose version --short 2>/dev/null)"; then ok "docker compose v2 plugin $v"; else fail "docker compose v2 plugin missing (the dev stack needs 'docker compose', not docker-compose v1)"; fi
  if docker info >/dev/null 2>&1; then
    daemon=1; ok "Docker daemon reachable"
  else
    fail "Docker daemon NOT reachable: 'up'/'exec'/'logs' cannot work here (only 'docker compose config' does)"
  fi
fi

# 2. compose file validity (daemon-less)
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if out="$(cd "$repo" && docker compose -f docker-compose.dev.yml config --quiet 2>&1)"; then
    ok "docker-compose.dev.yml parses ($(cd "$repo" && docker compose -f docker-compose.dev.yml config --services 2>/dev/null | wc -l) default services)"
  else
    fail "docker-compose.dev.yml does not parse: $(printf '%s' "$out" | head -1)"
  fi
fi

# 3. submodules = build contexts for api_dev / front_dev / migrate / workers
for sm in api front; do
  if [ -f "$repo/$sm/Dockerfile.dev" ]; then
    ok "$sm/ populated ($sm/Dockerfile.dev present; gitlink $(git -C "$repo" ls-tree HEAD "$sm" 2>/dev/null | awk '{print substr($3,1,12)}'))"
  else
    fail "$sm/ is empty: build context ./$sm has no Dockerfile.dev. .gitmodules uses SSH URLs; without an SSH key run: git -c url.\"https://github.com/\".insteadOf=\"git@github.com:\" submodule update --init --depth 1 $sm (build-and-env section 2b step 1)"
  fi
done
[ -f "$repo/events-processor/Dockerfile.dev" ] && ok "events-processor/Dockerfile.dev present"

# 4. Traefik TLS material (traefik/dynamic.yml expects these two files)
cert="$repo/traefik/certs/lago.dev.pem"; key="$repo/traefik/certs/lago.dev-key.pem"
if [ -f "$cert" ] && [ -f "$key" ]; then
  ok "traefik/certs/lago.dev.pem + lago.dev-key.pem present"
  if command -v openssl >/dev/null 2>&1; then
    if openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then ok "certificate not expired"; else fail "certificate expired or unreadable: regenerate with mkcert (docs/dev_environment.md:88-93)"; fi
    san="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tr -d ' \n')"
    case "$san" in *'*.lago.dev'*) ok "certificate SAN covers *.lago.dev" ;; *) warn "certificate SAN does not list *.lago.dev (got: ${san:-none})" ;; esac
    a="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)"; b="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null)"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "certificate and key match"; else fail "certificate and key do NOT match"; fi
  else
    skip "openssl not installed: cannot inspect the certificate"
  fi
else
  fail "missing traefik/certs/lago.dev.pem and/or lago.dev-key.pem: mkcert -install; cd traefik && mkdir -p certs && cd certs && mkcert -cert-file lago.dev.pem -key-file lago.dev-key.pem lago.dev '*.lago.dev'"
fi

# 5. hosts: every Host() rule in the dev compose must resolve to loopback
mapfile -t hosts < <(grep -oE 'Host\(`[^`]+`\)' "$dcf" | sed -E 's/Host\(`([^`]+)`\)/\1/' | sort -u)
for h in "${hosts[@]}"; do
  addr="$(getent hosts "$h" 2>/dev/null | awk '{print $1; exit}')"
  case "$addr" in
    127.*|::1) ok "hosts: $h -> $addr" ;;
    "") if [ "$h" = api.lago.dev ] || [ "$h" = app.lago.dev ]; then fail "hosts: $h does not resolve: add '127.0.0.1 $h' to /etc/hosts"; else warn "hosts: $h does not resolve (add '127.0.0.1 $h' to /etc/hosts)"; fi ;;
    *) warn "hosts: $h resolves to $addr, not loopback" ;;
  esac
done
info "Host() rules in compose: ${#hosts[@]} (${hosts[*]}); docs/dev_environment.md:99-105 lists license.lago.dev (no service) and omits console.lago.dev, pghero.lago.dev"

# 6. API files the docs ask for (api/.env is loaded by Dotenv in development; missing file is tolerated by Rails, UNVERIFIED for master.key)
if [ -f "$repo/api/Dockerfile.dev" ]; then
  if [ -f "$repo/api/.env" ]; then ok "api/.env present"; else warn "api/.env missing: cp ./api/.env.dist ./api/.env (docs/dev_environment.md:112)"; fi
  if [ -f "$repo/api/config/master.key" ]; then ok "api/config/master.key present"; else warn "api/config/master.key missing: touch ./api/config/master.key (docs/dev_environment.md:113)"; fi
else
  skip "api/.env and api/config/master.key: api/ is empty"
fi

# 7. .env.development overrides (git-ignored, optional)
ed="$repo/.env.development"
if [ -f "$ed" ]; then
  info ".env.development present ($(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$ed") assignments; it overrides .env.development.default for every env_file service)"
  if grep -qE '^LAGO_CLICKHOUSE_ENABLED=["'\'']?false' "$ed"; then
    warn ".env.development sets LAGO_CLICKHOUSE_ENABLED=false: MIXED in lago-api (the 12 .present?/.blank? readers stay ON; only org creation and 2 seed files turn off); set it empty to disable (see config-and-flags)"
  fi
  if grep -qE '^POSTGRES_PASSWORD=' "$ed"; then
    warn ".env.development overrides POSTGRES_PASSWORD: 'changeme' is hard-coded in lago-api config/database.yml (development direct/events roles) and extra/debezium_config.json (inferred breakage)"
  fi
  for v in POSTGRES_USER POSTGRES_DB; do
    if grep -qE "^$v=" "$ed"; then
      warn ".env.development overrides $v: 'lago' is hard-coded in scripts/postgresql.conf:86-88 (pg_partman_bgw role/dbname), lago-api config/database.yml development block and extra/debezium_config.json (inferred breakage)"
    fi
  done
else
  info ".env.development absent (optional; defaults come from .env.development.default)"
fi

# 8. external volume (compose refuses to start front without it)
if [ "$daemon" = 1 ]; then
  if docker volume inspect lago_front_pnpm_store >/dev/null 2>&1; then ok "external volume lago_front_pnpm_store exists"; else fail "external volume lago_front_pnpm_store missing (declared external: docker-compose.dev.yml:11-12): docker volume create lago_front_pnpm_store"; fi
else
  skip "external volume lago_front_pnpm_store: needs the Docker daemon (create it with: docker volume create lago_front_pnpm_store)"
fi

# 9. host ports the dev stack publishes
for p in 80 443 5432 6379 9000 9092 19092 8083; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
    warn "port $p on 127.0.0.1 is already in use (fine if it is the dev stack itself; otherwise 'up' fails to bind)"
  else
    ok "port $p free"
  fi
done

# 10. the `lago` alias
if [ -n "${LAGO_PATH:-}" ]; then info "LAGO_PATH=$LAGO_PATH"; else info "LAGO_PATH unset (only the 'lago' alias needs it)"; fi
lt="$(type -t lago 2>/dev/null || true)"
case "$lt" in
  file) warn "'lago' on PATH is a BINARY ($(command -v lago)), probably getlago/lago-cli: it has no 'exec'/'up -d' semantics of docker compose; use 'docker compose -f docker-compose.dev.yml ...'" ;;
  "")   info "'lago' alias not visible in this (non-interactive) shell: use 'docker compose -f docker-compose.dev.yml ...' in scripts and agents" ;;
  *)    info "'lago' is a shell $lt here" ;;
esac

echo "dev-preflight: $fails FAIL(s)"
exit "$fails"
