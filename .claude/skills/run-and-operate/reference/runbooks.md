# Bring-up runbooks (all variants)

Read when you are about to start, upgrade or tear down a stack. All commands run from the repo root
unless stated. Every `docker compose up/exec/logs/run` line is **not runnable in a daemon-less sandbox;
verified by reading the cited file**. Everything marked "ran" was executed on 2026-10-01.
`$API` = pinned lago-api checkout: `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)` (591ae90).

Never use the `lago` alias in scripts or agent shells: it is a shell alias
(`docs/dev_environment.md:52-53`) that non-interactive shells do not load, and the getlago/lago-cli binary
of the same name has no `exec`. Write `docker compose -f docker-compose.dev.yml ...` instead.

## R1. Dev stack (`docker-compose.dev.yml`, project `lago_dev`)

**Steps 1-4: prerequisites.** Owner: `build-and-env` §2b steps 1-6 (commands and verification there):
submodules over the HTTPS rewrite (`.gitmodules` uses `git@github.com:` URLs, so a plain
`git submodule update --init` fails without an SSH key), mkcert certificates in `traefik/certs`
(names from `traefik/dynamic.yml`; git-ignored, .gitignore:11), `/etc/hosts`, `api/.env` +
`api/config/master.key`, and the external volume `lago_front_pnpm_store`. Operator notes:
- Never commit the moved gitlinks (change-control N1).
- Hosts: the compose file routes 8 hosts (`api app console mail pdf pghero traefik webhook` `.lago.dev`);
  the doc list (docs/dev_environment.md:99-105) omits console and pghero and adds `license.lago.dev`.
  `lago.dev` is a real public domain: on 2026-10-01 `getent hosts pdf.lago.dev` returned a public
  address in this sandbox, so a missing hosts entry can silently send your browser to the internet.
- `api/.env` only fills vars that are still unset (`$API/config/environments/development.rb:76`
  `Dotenv.load`); the compose `env_file` values win.
- `lago_front_pnpm_store` is external (`docker-compose.dev.yml:11-12`, added `195bbc0`): compose
  refuses to start `front` without it.

Check steps 1-4 (ran): `.claude/skills/run-and-operate/scripts/dev-preflight.sh` → aim for
`dev-preflight: 0 FAIL(s)`. In this sandbox it reports 6 FAILs: no daemon, empty `api/` and `front/`, no
certs, `api.lago.dev` and `app.lago.dev` unresolved.

Optional overrides go in `.env.development` (git-ignored). Do not set `LAGO_CLICKHOUSE_ENABLED=false`
(MIXED: the 12 `.present?`/`.blank?` readers stay ON, only org creation and 2 seed files turn off; leave
it empty to disable) and do not change `POSTGRES_USER/PASSWORD/DB` (hard-coded in
`$API/config/database.yml` development roles, `extra/debezium_config.json`,
`scripts/postgresql.conf:86-88`). Semantics: `config-and-flags` §4.

5. Dependencies: `docker compose -f docker-compose.dev.yml up -d --wait db redis traefik clickhouse webhook`.
   `clickhouse` depends on `redpanda` and `redpandacreatetopics` (:465-471), so Redpanda and the 7 topics
   come up too. Topic creation is idempotent (`scripts/create-topics.sh`, `5477e39`).
6. App: `docker compose -f docker-compose.dev.yml up -d --wait front api api-worker api-clock`.
   `migrate` runs first (`./scripts/migrate.dev.sh`: RSA key generation + `db:prepare`), `api` runs
   `./scripts/start.dev.sh` (also `signup:seed_organization`). Open https://app.lago.dev.
7. Event pipeline (not in the docs' default list):
   `docker compose -f docker-compose.dev.yml up -d events-processor api-events-consumer`.
   `events-processor` runs `air` (hot reload, `.air.toml` `send_interrupt=true`, `kill_delay=10s`) on the
   bind-mounted source; `api-events-consumer` is the Karafka consumer of `events_charged_in_advance`.
8. Optional: `--profile mailpit` (`docker compose -f docker-compose.dev.yml --profile mailpit up -d --wait mailpit`;
   docs/dev_environment.md:292-302 says API mail raises a delivery error without it). Caveat (inferred
   by reading, not run): the pinned lago-api still sends dev mail to `mailhog:1025`
   (`$API/config/environments/development.rb:70-73`, `raise_delivery_errors = true` at :68), while
   `8f8334e` (#777, 2026-09-03) renamed the service to `mailpit` with no `mailhog` alias, so delivery
   likely fails until the lago-api pin catches up. Check with
   `grep -n 'address:' "$API/config/environments/development.rb"`.
   Also optional:
   `--profile redis-sentinel` (set `LAGO_REDIS_SIDEKIQ_SENTINELS`/`_MASTER_NAME` first; the doc example
   has a stray space after the comma, docs/dev_environment.md:199), dedicated workers (set
   `SIDEKIQ_<X>=true` in `.env.development` AND start `api-<x>-worker`, or jobs are never picked up).
9. Tests inside the stack: `docker compose -f docker-compose.dev.yml exec events-processor go test ./...`
   (the Docker-free equivalent is `.claude/skills/build-and-env/scripts/ep-test.sh`, an accepted pre-PR gate:
   DECIDED OD-5 (owner, 2026-10-02); `lago exec events-processor go test ./...` stays valid for dev-stack users).
10. Teardown: `docker compose -f docker-compose.dev.yml down` (keeps volumes).
    WARNING (dev only): `down -v` DELETES the `lago_dev_*` volumes (Postgres, Redis, Redpanda topics,
    ClickHouse data); it never removes the external `lago_front_pnpm_store`. Never run `down -v` against
    a self-host project.

Failure points seen in history: dependency races (`c80a7b5`, fixed with `service_healthy`), non-idempotent
topic creation (`5477e39`), a Traefik label on a non-existent `ws` entrypoint (`12b8101`), the `lago_test`
DB not created because the init-script path was wrong (fixed in `e5392e9`, #621; init scripts only run on
an EMPTY volume).

## R2. Root self-host (`docker-compose.yml`)

Maintained (bumped each release, CI-exercised by `docker-ci.yml`). No Kafka/ClickHouse/events-processor:
events use the Postgres store.

1. `git clone --depth 1 https://github.com/getlago/lago.git && cd lago` (README.md:222-223).
2. Write `.env` (compose reads it from the project dir). Minimum:
   ```bash
   echo "LAGO_RSA_PRIVATE_KEY=\"$(openssl genrsa 2048 | openssl base64 -A)\"" >> .env   # README.md:225
   for k in SECRET_KEY_BASE:64 LAGO_ENCRYPTION_PRIMARY_KEY:32 LAGO_ENCRYPTION_DETERMINISTIC_KEY:32 LAGO_ENCRYPTION_KEY_DERIVATION_SALT:32 POSTGRES_PASSWORD:16; do
     echo "${k%%:*}=$(openssl rand -hex "${k##*:}")" >> .env; done
   echo "LAGO_SIDEKIQ_WEB=false" >> .env; echo "LAGO_DISABLE_SEGMENT=true" >> .env
   ```
   The README stops at the RSA key; without the others the stack runs on public placeholders
   (`your-secret-key-base-hex-64`, `changeme`, ...). Hardening detail: `security-and-supply-chain`.
   (Ran 2026-10-01 in a temp dir: this snippet gives `selfhost-preflight: 0 FAIL(s)`.)
   RSA key format (checked 2026-10-01 with ruby against `$API/config/initializers/rsa_keys.rb:10-17` on
   the value `docker compose config` passes): one-line base64 → OK; base64 wrapped inside double quotes
   → OK (compose joins the lines, `Base64.decode64` ignores newlines); raw PEM, or base64 wrapped over
   unquoted lines (compose keeps only the first line) → `OpenSSL::PKey::RSAError: Neither PUB key nor
   PRIV key`; empty → abort `Private key is blank`. Keep it on one line (`openssl base64 -A`, `5dd6570`).
   Set these BEFORE the first `up`: the postgres image applies `POSTGRES_PASSWORD` only when it
   initialises an empty volume (standard image behaviour), and changing `LAGO_ENCRYPTION_*` after data
   exists makes encrypted columns unreadable (UNVERIFIED runtime; standard ActiveRecord encryption).
3. Preflight (ran on fixtures): `.claude/skills/run-and-operate/scripts/selfhost-preflight.sh .env` →
   `selfhost-preflight: 0 FAIL(s)`.
4. `docker compose up -d --wait`; check `curl -f http://localhost:3000/health` and `curl -f http://localhost`.
5. Remote access: set `LAGO_API_URL` and `LAGO_FRONT_URL` (defaults `http://localhost:3000` /
   `http://localhost`, docker-compose.yml:16,18). TLS: commented nginx/certbot recipes (:163-192) need
   `extra/init-letsencrypt.sh` (docker-compose v1, certbot service commented out): treat as UNVERIFIED.
6. Logs: `docker compose logs -f api api-worker api-clock migrate`.

**Upgrade trap: PG 14 → 15 on the same volume.** `97d1f0b` (2026-01-27, #673) switched `db` from
`postgres:14-alpine` to `getlago/postgres-partman:15.0-alpine` on the same `lago_postgres_data` volume;
the first release containing it is v1.41.0 (`12d0579`; v1.40.1 was tagged on a branch without it).
PostgreSQL refuses to start on a data directory from an older major (standard behaviour; message like
"database files are incompatible with server"; not run here). No doc in this repo mentions it. If you
upgrade from v1.40.x or older with an existing volume (CANDIDATE procedure, not run here):
```bash
# 1. while still on the OLD compose file (postgres:14-alpine)
docker compose exec -T db pg_dumpall -U lago > lago-pg14.sql      # verify the file before going on
docker compose down
# 2. confirm what is on the volume (<project> = directory name, e.g. lago)
docker run --rm -v <project>_lago_postgres_data:/d alpine cat /d/postgres/PG_VERSION   # prints 14
# WARNING: the next line DELETES every row in the database; run it only after the dump is verified
docker volume rm <project>_lago_postgres_data
# 3. new compose file (partman 15)
docker compose up -d --wait db
docker compose exec -T db psql -U lago -d postgres < lago-pg14.sql
docker compose up -d --wait
```
Release-note ownership: `release-and-images`; incident chronicle: `failure-archaeology`.

## R3. deploy/ variants (local / light / production) — STALE, use with care

Images pinned `v1.27.1`; defects DC1-DC10 and deploy.sh DS1-DS11 in `variants.md`. Working commands
(profile BEFORE `up`):
```bash
cd deploy
cp .env.production.example .env        # light: .env.light.example; local needs none
# fill LAGO_DOMAIN, LAGO_ACME_EMAIL (+ PORTAINER_USER/PASSWORD for production) and ALL secrets of R2 step 2
../.claude/skills/run-and-operate/scripts/selfhost-preflight.sh --variant production .env
docker compose -f docker-compose.production.yml --profile all up -d
```
- `docker compose up --profile all` (deploy/README.md) fails: `unknown flag: --profile` (ran, `--dry-run`).
- Without a profile, db/redis/rsa-keys are not started (their `profiles:` keys,
  deploy/docker-compose.production.yml:119,138,149).
- `deploy.sh` (interactive, downloads from deploy.getlago.com): avoid; if a run left `✅ ... is already
  set` lines in `.env`, delete them (selfhost-preflight flags them as `line N: not KEY=VALUE`).
- production: also fix or remove `pdf-worker` (missing script, deploy/docker-compose.production.yml:346) and decide on `SIDEKIQ_*=true` routing,
  otherwise dedicated workers idle (OPEN question for the owner; see change-control before editing
  deploy/, class C6).
- Before trusting TLS: the ACME resolver uses the Let's Encrypt STAGING CA (production.yml:87).

## R4. All-in-one image (`getlago/lago`, testing/staging only)

```bash
docker run -d --name lago -p 80:80 -p 3000:3000 -v lago_data:/data getlago/lago:v1.53.0
docker logs -f lago                       # app logs (foreman)
docker exec lago cat /data/db.log         # db:create/migrate/seed output
```
- Pin a version tag rather than `latest`, and check it exists: some `getlago/lago` tags were never
  published (as of 2026-10-01; list: `release-and-images`). The README command (docker/README.md:22) has no `-v`: data then lives in an
  anonymous volume that the next `docker run` will not reuse.
- PDF: add `-v /var/run/docker.sock:/var/run/docker.sock` (root-equivalent on the host) and, on Linux,
  `--add-host=host.docker.internal:host-gateway` (inferred from runner.sh:19).
- Changing config after first boot: edit `/data/.env` (values there win over `-e`; runner.sh:23-25).
- Persistence of Postgres/Redis data under `/data`: UNVERIFIED (see variants.md §5).

## R5. events-processor standalone (binary, no compose)

```bash
source .claude/skills/build-and-env/scripts/ep-env.sh            # CGO_LDFLAGS + LD_LIBRARY_PATH
out=$(mktemp -d); (cd events-processor && go build -o "$out/event_processors" .)   # never build into the repo
LAGO_KAFKA_BOOTSTRAP_SERVERS=localhost:19092 \
LAGO_KAFKA_RAW_EVENTS_TOPIC=events-raw LAGO_KAFKA_CONSUMER_GROUP=lago_dev \
LAGO_KAFKA_ENRICHED_EVENTS_TOPIC=events_enriched \
LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC=events_charged_in_advance \
LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC=events_dead_letter \
DATABASE_URL=postgresql://lago:changeme@localhost:5432/lago \
LAGO_REDIS_STORE_URL=localhost:6379 LAGO_REDIS_STORE_DB=1 ENV=development \
"$out/event_processors"
```
Values above target a running dev stack from the host (Redpanda external listener 19092,
docker-compose.dev.yml:377-378). The build (ran) gives a 58,101,160-byte binary. The README's
`go build -o event_processors .` inside `events-processor/` leaves an UN-ignored binary
(`events-processor/.gitignore` ignores only `events-processor`, `git check-ignore` confirms).
Without a broker, run it only to check the startup contract (outputs in `events-processor-ops.md` §1).
End-to-end without Docker: the `diagnostics-and-tooling` skill's binary smoke (kfake + miniredis +
scratch Postgres; ran 2026-10-01: 9 raw events, committed offset 9, clean SIGTERM exit).

## R6. Agentic AI demo

`./examples/agentic-ai-demo/run.sh` (needs Docker daemon, curl, jq). Ran here: `--help` exits 0; with no
daemon it prints `Docker is installed but the Docker daemon is not available.` and exits 1. Ports:
`LAGO_DEMO_UI_PORT` (8080), `LAGO_DEMO_API_PORT` (3001), bound to 127.0.0.1. Cleanup:
`./examples/agentic-ai-demo/run.sh --cleanup`.

## R7. Connectors

No runnable recipe in the repo (private ECR image only, no compose service). If you must run one, start
from `variants.md` §7 and treat the result as UNVERIFIED. Value trap: a JSON-number
`precise_total_amount_cents` is passed through and the events-processor drops the record (unmarshal
error, committed, Sentry only, no DLQ); any non-number becomes `"0"` (connectors/http.yml:32-36). There
is no value-preserving workaround through the connectors; the fix is `event-accounting-campaign` W2.
