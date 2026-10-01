# Self-host defaults and exposure: full table

Read this when you audit or harden a self-host plane (root `docker-compose.yml`, `deploy/*`,
the all-in-one `getlago/lago` image), or when you review a C6/C7 change to any of them.

All rows were checked on 2026-10-01 against HEAD (code at `5308258`) and lago-api at the
pinned SHA `591ae90` (`$API` = `pinned-checkout.sh api`). Line numbers are repo-relative.
"Inferred" means it follows from the cited lines but was not exercised (no Docker daemon here).

## 1. Planes

| Plane | Files | Who runs it |
|---|---|---|
| root self-host | `docker-compose.yml` + optional `.env` | README "Deploy Lago" (`README.md:217-227`), `docker-ci.yml` |
| deploy local | `deploy/docker-compose.local.yml` | `deploy/deploy.sh` option Local, `deploy/README.md` |
| deploy light | `deploy/docker-compose.light.yml` + `deploy/.env.light.example` | deploy.sh Light |
| deploy production | `deploy/docker-compose.production.yml` + `deploy/.env.production.example` | deploy.sh Production |
| all-in-one image | `docker/Dockerfile`, `docker/runner.sh` | `docker run getlago/lago` (`docker/README.md:21-29`), "testing and staging only" (`docker/README.md:5`) |
| dev | `docker-compose.dev.yml`, `.env.development.default`, `traefik/`, `extra/clickhouse/`, `extra/debezium_config.json` | contributors; listed for completeness, never for exposure on a network |

## 2. Placeholder secrets that ship as working defaults

The compose files use `${VAR:-placeholder}`. If the operator does not set `VAR`, the app runs with
the public placeholder. For Light/Production, `deploy/deploy.sh:236` prompts for `LAGO_DOMAIN
LAGO_ACME_EMAIL PORTAINER_USER PORTAINER_PASSWORD` (plus `POSTGRES_*`/`REDIS_*` only when you choose
an external database or Redis, `:249-262`); it never prompts for `SECRET_KEY_BASE` or the encryption
keys, and never for `POSTGRES_PASSWORD` of the bundled database. `deploy/.env.light.example` holds only
`LAGO_DOMAIN` and `LAGO_ACME_EMAIL`; `deploy/.env.production.example` holds those plus the two
`PORTAINER_*` keys.

| Secret | Placeholder label | Root | local | light | production | What it protects (`$API`) | Impact if left as default |
|---|---|---|---|---|---|---|---|
| `SECRET_KEY_BASE` | `your-secret-key-base` | `:24` | `:27` | `:30` | `:30` | HS256 signing key of the session JWT (`app/services/utils/auth_token.rb:6,12,18`); `MessageVerifier` for customer-portal tokens (`app/controllers/concerns/customer_portal_user.rb:9`, `app/services/customer_portal/generate_url_service.rb:16`) | Anyone who knows a user id or customer id can mint a valid `x-lago-token` / portal token (inferred from the code) |
| `LAGO_ENCRYPTION_PRIMARY_KEY`, `_DETERMINISTIC_KEY`, `_KEY_DERIVATION_SALT` | `your-encryption-key` | `:29-31` | `:32-34` | `:35-37` | `:35-37` | ActiveRecord encryption (`config/application.rb:35-37`) of `secrets` (`app/models/concerns/secrets_storable.rb:7`), used by payment providers and integrations (`app/models/payment_providers/base_provider.rb`, `app/models/integrations/base_integration.rb`) | A DB dump or DB access decrypts payment-provider and integration credentials with public keys |
| `POSTGRES_PASSWORD` (and `DATABASE_URL`) | `changeme` | `:97` (`:21`) | `:87` (`:24`) | `:111` (`:27`) | `:111` (`:27`) | the whole database | Combined with the published 5432 port (section 3): remote DB login with a public password |
| `LAGO_AWS_S3_ACCESS_KEY_ID` / `_SECRET_ACCESS_KEY` | `azerty123456` | `:33-34` | `:36-37` | `:39-40` | `:39-40` | S3 storage, only when `LAGO_USE_AWS_S3=true` | Low by itself (not valid AWS keys); hides a missing configuration |
| Portainer `ADMIN_PASSWORD` | `changeme` | - | - | - | `:465` (`ADMIN_USER` `:464`) | Portainer UI routed at `https://<LAGO_DOMAIN>/portainer` (`:469`), which holds the docker socket (`:461`) | Whether `portainer-ce` honours `ADMIN_USER`/`ADMIN_PASSWORD` env is UNVERIFIED; if it does, the default is public |
| ACME email | `acme-example-email` | - | - | `:85` | `:85` | Let's Encrypt account | Not a secret; expiry mails go nowhere |
| `REDIS_PASSWORD` | empty | `:23` | - | - | - | Sidekiq/cache Redis | Bundled Redis never sets `--requirepass` (section 3) |

The single image is different: `docker/runner.sh:5-21` generates `POSTGRES_PASSWORD`,
`SECRET_KEY_BASE`, the RSA key and the three encryption keys with `openssl` on first start and
appends them in plaintext to `/data/.env` (`runner.sh:64-69`, `:71-74`). Notes:
- `SECRET_KEY_BASE=$(openssl rand -base64 16)` (`runner.sh:9`) is 16 random bytes. CANDIDATE: use
  `openssl rand -hex 64`, the size `bin/rails secret` produces.
- `/data/.env` is parsed with `for LINE in $(cat /data/.env); do export $LINE; done` (`runner.sh:24`):
  values with spaces or quotes break.
- Anyone who can read the `/data` volume reads every generated secret.

## 3. Network exposure

Compose `ports: - "5432:5432"` binds all host interfaces. Docker publishes through its own
iptables chains, so a host firewall such as UFW does not see these ports (standard Docker
behaviour; not exercised here).

| Exposure | Root | local | light | production | dev | Notes |
|---|---|---|---|---|---|---|
| Postgres 5432 on all interfaces | `:104` | `:94` (profile `all`) | `:118` | `:118` | `:54` | with `changeme` unless overridden |
| Redis 6379 on all interfaces, no `requirepass` | `:119` (svc `:106`) | `:113` (svc `:100`) | `:137` (svc `:124`) | `:137` (svc `:124`) | `:78` (`--requirepass` only if `REDIS_PASSWORD` set, `:70`) | whether the image's protected mode blocks remote clients is UNVERIFIED |
| API 3000 (serves `/sidekiq`, `/metrics`) | `:157` | `:174` | via Traefik `/api/` (`:203-205`) | via Traefik `/api/` (`:203-205`) | via Traefik `api.lago.dev` | see section 4 |
| Traefik dashboard, `--api.insecure=true`, port 8080 | - | - | `:80`, `:89` | `:80`, `:89` | `traefik/traefik.yml:19-21`, router `traefik.lago.dev` (`docker-compose.dev.yml:33-37`) | the insecure API has no auth; it shows routers, services and backends |
| docker.sock mounted | - | - | Traefik `:92` | Traefik `:92`, Portainer `:461` | Traefik `:31` | `:ro` on a socket does not make the Docker API read-only; whoever controls the container controls the host |
| ClickHouse 9000, user `default`/`default` from `::/0` | - | - | - | - | `:477`; `extra/clickhouse/users.d/users.xml:15-17,23` | dev only |
| Kafka 9092/19092, Kafka Connect REST 8083 (no auth) | - | - | - | - | `:382-383`, `:441` | dev only; Connect REST accepts connector configs from anyone who reaches it |

Run `scripts/secret-defaults-scan.sh` to regenerate sections 2 and 3 (counts in SKILL.md).

## 4. Sidekiq Web and other unauthenticated endpoints

- `$API/config/routes.rb:4-6`: when `ENV["LAGO_SIDEKIQ_WEB"] == "true"`, mount `Sidekiq::Web` at
  `/sidekiq` and the Prometheus exporter at `/sidekiq/prometheus/metrics`.
- `$API/config/initializers/sidekiq.rb:22-28`: adds only `ActionDispatch::Cookies` and a cookie
  session. No authentication middleware exists in `$API/config`, `app` or `lib` (0 hits for
  `Rack::Auth::Basic`, `Sidekiq::Web.use ... Auth`, `constraints ... Sidekiq`).
- Default `LAGO_SIDEKIQ_WEB` is `true` in every compose plane: `docker-compose.yml:28`,
  `deploy/docker-compose.local.yml:31`, `light.yml:34`, `production.yml:34`,
  `.env.development.default:6`. The single image leaves it unset (OFF).
- Reach (inferred from config): root/local `http://<host>:3000/sidekiq`; light/production
  `https://<LAGO_DOMAIN>/api/sidekiq` (router `PathPrefix(/api/)` + `stripprefix /api`,
  `production.yml:203-205`).
- What an anonymous visitor gets (Sidekiq Web features; UNVERIFIED for this version): queue and job
  views with job arguments (ids, webhook payloads), retry/delete/kill buttons.
- Also always mounted: `Yabeda::Prometheus::Exporter` at `/metrics` (`routes.rb:10`). The Karafka
  Web UI mounts at `/karafka` when `LAGO_KARAFKA_WEB` is set to any value, including empty
  (`routes.rb:8`); the root/deploy anchors do not pass that variable. Dev sets it to empty
  (`.env.development.default:91`; `docker compose -f docker-compose.dev.yml config api` shows
  `LAGO_KARAFKA_WEB: ""`). An empty string is truthy in Ruby, so the dev API mounts `/karafka`
  (inferred, not exercised; dev only).
- Run `scripts/sidekiq-web-exposure.sh` for the per-plane verdict.

OPEN question for the owner (route via change-control): should `LAGO_SIDEKIQ_WEB` default to
`false` in self-host files, or is an upstream auth layer expected? Nothing in this repo or the
pinned lago-api provides one.

## 5. TLS certificates and telemetry

- Let's Encrypt **staging** CA is hard-coded in `deploy/docker-compose.light.yml:87` and
  `production.yml:87` (`caServer=https://acme-staging-v02...`). Browsers do not trust staging
  certificates. `deploy/README.md` does not mention it.
- `extra/init-letsencrypt.sh` (root-compose nginx variant) is NOT on staging: `staging=0` (`:12`).
  It hard-codes a named employee e-mail address (`:11`), needs the v1 `docker-compose` binary
  (`:3-6`), and downloads TLS parameters from certbot's `master` branch without a checksum
  (`:24-26`). Its output dir `./extra/certbot` (`:10`) is not git-ignored (`.gitignore:8` ignores
  `/extra/ssl/certbot`), so generated private keys could be committed by `git add -A`.
- Segment telemetry: `$API/config/initializers/analytics_ruby.rb:3` enables it unless
  `LAGO_DISABLE_SEGMENT == "true"`. Root passes `${LAGO_DISABLE_SEGMENT}` (`docker-compose.yml:52`,
  empty), deploy files pass `${LAGO_DISABLE_SEGMENT:-}` (`:53`/`:56`/`:56`). This is documented and
  intentional: `README.md:262` ("collect basic product analytics by default", with an opt-out link).
  Official `getlago/api` images bake `SEGMENT_WRITE_KEY` in at build time (`$API/Dockerfile:42,46`,
  `$API/.github/workflows/release.yml:66`). `docker/Dockerfile` declares no such ARG, although
  `.github/workflows/release-docker-image.yml:62` passes one, so the all-in-one image falls back to
  `"changeme"` (`analytics_ruby.rb:20`) (inferred).

## 6. Hardening recipe (self-hoster; root compose shown, deploy files are analogous)

Generate secrets once and keep `.env` out of git (`.gitignore:3` already ignores `.env`):

```bash
cd "$(git rev-parse --show-toplevel)"     # or the directory holding docker-compose.yml
umask 077
{
  echo "SECRET_KEY_BASE=$(openssl rand -hex 64)"
  echo "LAGO_ENCRYPTION_PRIMARY_KEY=$(openssl rand -hex 32)"
  echo "LAGO_ENCRYPTION_DETERMINISTIC_KEY=$(openssl rand -hex 32)"
  echo "LAGO_ENCRYPTION_KEY_DERIVATION_SALT=$(openssl rand -hex 32)"
  echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
  echo "LAGO_RSA_PRIVATE_KEY=\"$(openssl genrsa 2048 2>/dev/null | openssl base64 -A)\""
  echo "LAGO_SIDEKIQ_WEB=false"
  echo "LAGO_DISABLE_SEGMENT=true"          # only if you opt out of telemetry
} >> .env
```

Do not print `.env` to share it. Verify with counts only (daemon-less, VERIFIED pattern):

```bash
docker compose -f docker-compose.yml config 2>/dev/null | grep -c -E 'your-secret-key-base|your-encryption-|changeme'
# expect 0 after the .env above; 26 with an empty environment
# (as of 2026-10-01; deploy/docker-compose.production.yml --profile all with LAGO_DOMAIN set: 52).
# The S3 placeholder azerty123456 stays until you set LAGO_AWS_S3_* (harmless unless LAGO_USE_AWS_S3=true).
docker compose -f docker-compose.yml config api 2>/dev/null | grep -m1 'LAGO_SIDEKIQ_WEB'
# expect: LAGO_SIDEKIQ_WEB: "false"   (VERIFIED in a scratch copy with the .env above)
```

Then, as file changes (C6 + C7, owner review via change-control):
1. Remove the `ports:` of `db` and `redis`, or bind them to loopback (`127.0.0.1:5432:5432`).
2. Give the bundled Redis a password: `command: --port ${REDIS_PORT:-6379} --requirepass ${REDIS_PASSWORD:?set REDIS_PASSWORD}`
   and `redis-cli -a "$REDIS_PASSWORD"` in the healthcheck. CANDIDATE: not tested here.
3. Light/production: drop `--api.insecure=true` and the `8080:8080` mapping (or bind
   `127.0.0.1:8080:8080`); delete the `caServer=...acme-staging...` line after a staging dry run.
4. Production: pin `portainer/portainer-ce` to a version and set a real `PORTAINER_PASSWORD`, or
   drop Portainer.
5. Changing the encryption keys after data exists makes existing encrypted `secrets` unreadable
   unless the old keys are kept as previous keys (standard ActiveRecord encryption behaviour;
   UNVERIFIED for lago-api). Plan rotation; do not just swap them on a live install.

Not runnable here: `docker compose up`. The recipe's `config` commands are runnable without a daemon.
