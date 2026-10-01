# Runtime variants: full service matrix, drift, deploy.sh defects

Read when you need the exact service list, image tag, port or volume of a variant, or when a
deploy/ or all-in-one install misbehaves. Facts verified 2026-10-01. Code facts as of 5308258
(events-processor tree 83e012866f29); the working branch may carry skills-only commits on top.
Regenerate the tables with `.claude/skills/run-and-operate/scripts/compose-matrix.sh` (daemon-less).

## 1. Compose files tracked in git (6)

`git ls-files | grep -E 'compose[^/]*\.ya?ml$'` → `docker-compose.yml`, `docker-compose.dev.yml`,
`deploy/docker-compose.{local,light,production}.yml`, `examples/agentic-ai-demo/compose.yml`.
All 6 pass `docker compose config --quiet` with an empty environment (compose v5.3.1).

| File | Project name | Unset-var warnings with empty env | Profiles |
|---|---|---|---|
| `docker-compose.yml` | directory name (no `name:` key; `lago` after a plain clone) | 25 (`LAGO_AWS_S3_ENDPOINT LAGO_DISABLE_SEGMENT LAGO_DISABLE_WALLET_REFRESH LAGO_REDIS_CACHE_PASSWORD LAGO_RSA_PRIVATE_KEY`) | none |
| `docker-compose.dev.yml` | `lago_dev` (:1) | 0 | `mailpit`, `redis-sentinel` |
| `deploy/docker-compose.local.yml` | `lago-local` | 0 | `all all-no-db all-no-keys all-no-pg all-no-redis` |
| `deploy/docker-compose.light.yml` | `lago-light` | 16 (`LAGO_DOMAIN`) | same five |
| `deploy/docker-compose.production.yml` | `lago-production` | 27 (`LAGO_DOMAIN`) | same five |
| `examples/agentic-ai-demo/compose.yml` | `agentic-ai-demo` (run.sh overrides: `-p lago-agentic-ai-demo`, run.sh:8) | 0 | none |

## 2. Root self-host `docker-compose.yml` (maintained: bumped every release, CI-exercised)

CI: `.github/workflows/docker-ci.yml` runs `docker compose up -d --wait` on every push to main, then
`curl -f :3000/health`, `:80`, and `GET /api/v1/customers` with the seeded key (docker-ci.yml:16-32).

| Service | Image | Host port | Volumes | Command |
|---|---|---|---|---|
| db | `getlago/postgres-partman:15.0-alpine` (:7) | `${POSTGRES_PORT:-5432}` (:104) | `lago_postgres_data:/data/postgres` | image default |
| redis | `redis:7-alpine` | `${REDIS_PORT:-6379}` (:119) | `lago_redis_data:/data` | `--port ${REDIS_PORT}` (no password) |
| migrate | `getlago/api:v1.53.0` (:11) | - | - | `./scripts/migrate.sh` |
| api | same | `${API_PORT:-3000}:3000` (:157) | `lago_storage_data:/app/storage` | `./scripts/start.api.sh` |
| api-worker | same | - | `lago_storage_data` | `./scripts/start.worker.sh` |
| api-clock | same | - | - | `./scripts/start.clock.sh` |
| front | `getlago/front:v1.53.0` (:13) | `${FRONT_PORT:-80}:80` (:172) | - | image default (nginx) |
| pdf | `getlago/lago-gotenberg:7.8.2` (:338) | - | - | image default |

Not in this file: Kafka/Redpanda, ClickHouse, events-processor, rsa-keys. Dedicated workers and certbot
are commented out (:186-318). The `SIDEKIQ_*` hints at :67-73 are list syntax inside a mapping anchor:
uncommenting them as-is breaks YAML; write `"SIDEKIQ_EVENTS": "true"` instead.

`getlago/postgres-partman:15.0-alpine` = `postgres:15.0-alpine` + pg_partman v5.4.0 built in, CMD
`["postgres"]`, no config change (Docker Hub layer history via the hub.docker.com tags API, re-read
2026-10-01: `ENV PG_VERSION=15.0`, `ENV PARTMAN_VERSION=v5.4.0`, no CMD after the partman layer). So
pg_partman is AVAILABLE (migrations partition `enriched_events`) but `pg_partman_bgw` is NOT preloaded:
see `partitioning.md`.

## 3. Dev stack `docker-compose.dev.yml` (maintained; contributors' stack)

25 default services; `--profile mailpit` adds `mailpit`; `--profile redis-sentinel` adds
`redis-replica redis-sentinel-1 redis-sentinel-2 redis-sentinel-3` (30 with `--profile '*'`).

| Service | Image | Host ports | Traefik host | Named volumes |
|---|---|---|---|---|
| traefik | `traefik:v3` (:21) | 80, 443 | traefik.lago.dev | binds `./traefik/*.yml`, `./traefik/certs`, docker.sock |
| db | `getlago/postgres-partman:15.0-alpine` (:40) | 5432 | - | `postgres_data_dev:/data/postgres`; `-c config_file=/etc/postgresql.conf` (:43) |
| redis | `redis:7-alpine` | 6379 | - | `redis_data_dev` |
| front | `front_dev` (build `./front/Dockerfile.dev`, pull_policy never) | - | app.lago.dev | `front_node_modules_dev`, `front_dist_dev`, EXTERNAL `lago_front_pnpm_store` |
| webhook | `ghcr.io/tarampampam/webhook-tester:2` | - | webhook.lago.dev | - |
| migrate | `api_dev` (build `./api/Dockerfile.dev`) | - | - | bind `./api` |
| api | `api_dev` | - | api.lago.dev (web + websecure) | bind `./api` |
| api-worker + 7 dedicated workers (`api-{events,pdfs,billing,clock,webhook,analytics,ai-agent}-worker`) | `api_dev` | - | - | bind `./api` |
| api-clock, api-events-consumer (Karafka) | `api_dev` | - | - | bind `./api` |
| events-processor | `events-processor_dev` (build `./events-processor/Dockerfile.dev`, runs `air`) | - | - | bind `./events-processor:/app` |
| pdf | `getlago/lago-gotenberg:8` (:341) | - | pdf.lago.dev | - |
| mailpit (profile) | `axllent/mailpit:latest` | - | mail.lago.dev | - |
| redpanda | `docker.redpanda.com/redpandadata/redpanda:v25.2.10` (:369) | 9092, 19092 | - | `redpanda_data_dev` |
| redpandacreatetopics | same | - | - | runs `scripts/create-topics.sh` with 7 topics (:398-405) |
| redpanda-console | `docker.redpanda.com/redpandadata/console:v3.2.2` | - | console.lago.dev | - |
| redpanda-kafka-connect | `docker.redpanda.com/redpandadata/connectors:latest` | 8083 | - | bind `./extra/kafka-connect` (Debezium + ClickHouse plugins) |
| clickhouse | `clickhouse/clickhouse-server:26.2-alpine` (:460) | 9000 | - | `clickhouse_data_dev`; user `default`/`default` |
| pghero | `ankane/pghero:latest` | - | pghero.lago.dev | - |
| redis-replica, redis-sentinel-1..3 (profile) | `redis:7-alpine` | - | - | `redis_replica_data_dev` |

Every app service reads `env_file: .env.development.default` then optional `.env.development`.
Dependency edges follow change-control N12: infrastructure deps (db, redis, clickhouse, redpanda)
`condition: service_healthy`; one-shot jobs (migrate, redpandacreatetopics)
`service_completed_successfully`; app->api edges `service_started`; known exception redpanda-console ->
redpanda (short form). Counted 2026-10-01 with
`docker compose -f docker-compose.dev.yml --profile '*' config --format json`: 20 `service_healthy`,
12 `service_started` (11 app->api + redpanda-console), 2 `service_completed_successfully`.
`events-processor` waits for db, redpanda and redis healthy (:326-332) but has no healthcheck itself
(it has no endpoint).

## 4. deploy/ variants (STALE: images pinned v1.27.1 since `cd9f0fa` 2025-05-20)

Release bumps touch only the root file; `git log -S v1.27.1 -- deploy/` in the history clone shows only
`cd9f0fa`. Images: `postgres:15-alpine` (no partman), `redis:7-alpine`, `getlago/api|front:v1.27.1`,
`getlago/lago-gotenberg:8.15`; light/production add `traefik:v3.3`; production adds
`portainer/portainer-ce:latest`.

| Profile | local | light | production |
|---|---|---|---|
| (none) | api api-clock api-worker front migrate pdf | + traefik | api billing-worker clock clock-worker events-worker front migrate pdf pdf-worker portainer traefik webhook-worker worker (13) |
| `all` | + db redis rsa-keys (9) | + db redis rsa-keys (10) | + db redis rsa-keys (16) |
| `all-no-pg` | drops db | drops db | drops db |
| `all-no-redis` | drops redis | drops redis | drops redis |
| `all-no-db` | drops db and redis | same | same |
| `all-no-keys` | drops rsa-keys | same | same |

Known breakages (all verified by reading the file at 5308258 unless marked):

| # | Defect | Evidence |
|---|---|---|
| DC1 | README puts `--profile` after `up`: `docker compose up --profile all` → `unknown flag: --profile` (global flag; must precede `up`) | deploy/README.md:21,24,49,52,79,82,101-116,135,151,165; reproduced with `--dry-run` |
| DC2 | No profile = no db, no redis, no rsa-keys: migrate/api start with nothing to talk to | compose-matrix "services with no profile" |
| DC3 | production `pdf-worker` runs `./scripts/start.pdf.worker.sh`; lago-api has only `start.pdfs.worker.sh`, both at 591ae90 and at tag v1.27.1 (`git ls-tree --name-only HEAD scripts/` of a blob-less `--branch v1.27.1` clone) → container exits, `restart: unless-stopped` loops (inferred) | deploy/docker-compose.production.yml:346; `compose-matrix.sh --check-scripts` → `script MISSING` |
| DC4 | production dedicated workers get no `SIDEKIQ_*=true`, so no job is routed to their queues; they idle while `worker` does everything | `grep SIDEKIQ deploy/docker-compose.production.yml` shows only CONCURRENCY and SIDEKIQ_WEB |
| DC5 | Traefik: `--api.insecure=true` dashboard on host 8080, Let's Encrypt STAGING CA (untrusted certs), no :80 entrypoint | production.yml:80,87,89 (light same lines) |
| DC6 | db 5432 and redis 6379 published on the host; redis has no password | production.yml:117-118,136-137 |
| DC7 | redis healthcheck is `redis-cli ping` without `-p ${REDIS_PORT}` (root fixed in `b1e40bd`): a custom REDIS_PORT never turns healthy (inferred) | production.yml:129, light.yml:129, local.yml:105 |
| DC8 | no service `depends_on: rsa-keys`; first boot may race the key generation (UNVERIFIED runtime) | production.yml:143-168 |
| DC9 | missing vars vs root: `LAGO_DISABLE_PDF_GENERATION`, `LAGO_DATA_API_*`, `MISTRAL_*`; `LAGO_PDF_URL` hard-coded in light/production (:52) | diff of the anchors |
| DC10 | `x-lago-domain` anchor is never merged, so api/front never receive `LAGO_DOMAIN` (light.yml:21 has a TODO) | production.yml:19-20 |

### deploy/deploy.sh defects (interactive installer behind deploy.getlago.com)

| # | Defect | Line(s) |
|---|---|---|
| DS1 | downloads to `docker-compose.yml` but runs `-f docker-compose.local.yml|light.yml|production.yml`: outside a repo checkout the file does not exist | :169,179,190 vs :314,319,325 |
| DS2 | Local runs with no `--profile` → DC2 | :314 |
| DS3 | `.env` rewrite writes the `✅ VAR is already set.` status lines INTO `.env` (the echo is inside `{ ... } > "$ENV_FILE"`); compose then refuses the file (`unexpected character`), and every non-mandatory var (SECRET_KEY_BASE, ...) is dropped | :288-299 (:295) |
| DS4 | running-project detection is always empty (`$(... &>/dev/null)`) | :106 |
| DS5 | volume cleanup removes unprefixed names (`lago_postgres_data`); real names are `lago-<variant>_lago_*` | :115 vs compose-matrix volume lines |
| DS6 | `command -v "docker compose"` never succeeds; missing deps only warn | :58, :60-70 |
| DS7 | Light asks for PORTAINER_USER/PASSWORD although light has no portainer | :236 |
| DS8 | `$?` checks only the last curl; `curl -s` without `-f` saves an HTTP error page as the compose file | :179-181, :190-191 |
| DS9 | light/production `up` output discarded (`&>/dev/null`) and the success banner printed regardless of the exit status (local discards only the docker-compose v1 fallback) | :314, :319-320, :325-326, :331 |
| DS10 | never asks for SECRET_KEY_BASE / LAGO_ENCRYPTION_* → placeholder secrets | :236-264 |
| DS11 | GitHub Pages republishes `deploy/` only when `deploy/deploy.sh` changes, so edits to `deploy/*.yml` can lag on the served site (that deploy.getlago.com is this Pages site: UNVERIFIED) | `.github/workflows/gh-page.yml:7-8` |

History: `2453945` (#762, 2026-09-03) fixed `check_domain_dns: command not found` after 15 months;
`bash -n` does not catch these classes. For the chronicle, see `failure-archaeology`.

## 5. All-in-one image `getlago/lago` (`docker/`; testing/staging only per docker/README.md:5)

One container: nginx (front on :80), Rails api (:3000), Sidekiq worker, clockwork (foreman, `docker/Procfile`),
local Postgres 17 + pg_partman package, Redis (Debian `redis-server`). No Kafka, ClickHouse or
events-processor. Entry `./runner.sh` (Dockerfile:66), `VOLUME /data` (:64).

| Behaviour | Evidence | Status |
|---|---|---|
| Generates POSTGRES_PASSWORD, SECRET_KEY_BASE (16 random bytes, base64), RSA key, 3 encryption keys on first start and appends them in plaintext to `/data/.env` | runner.sh:5-21, 64-69 | verified by reading |
| `/data/.env` is exported line by line BEFORE defaults (`for LINE in $(cat ...)`): values with spaces break; a value persisted there wins over a later `docker run -e` | runner.sh:23-25 | verified by reading |
| docker/README.md:40 says default DATABASE_URL password is `lago`; runner.sh generates a random one | runner.sh:8,71-73 | doc stale |
| Postgres data dir: `PGDATA=/data/postgresql` is exported but `service postgresql restart` uses Debian's cluster config, so data likely stays in `/var/lib/postgresql/17/main`, outside the volume | runner.sh:43-48 | UNVERIFIED (needs a running container) |
| Redis data dir: `sed s#DATA_DIR#...` targets Debian's stock `/etc/redis/redis.conf` which has no placeholder; `docker/redis.conf` is no longer copied (since `9eb8c3b`) | runner.sh:40; docker/redis.conf:22 | UNVERIFIED runtime |
| PDF: only if docker.sock is mounted; starts a sibling `lago-pdf` (`getlago/lago-gotenberg:8`, host port 3001); app reaches it at `http://host.docker.internal:3001`, which Linux Docker does not resolve without `--add-host=host.docker.internal:host-gateway` (inferred) | runner.sh:19,52-60 | mounting docker.sock = root on the host |
| Migrations and seeding log to `/data/db.log`; failures are not checked before `foreman start` | runner.sh:84-93 | verified by reading |
| Postgres major jumped 15 → 17 in `b6b98c8` (2025-09-15) | git show b6b98c8 -- docker/Dockerfile | upgrade trap if data was persisted |

## 6. events-processor outside compose

- Dev: the `events-processor` service (above). Root/deploy/all-in-one: NOT present.
- Production-style: image `getlago/lago-events-processor` (release workflow; see `release-and-images`),
  entrypoint `./event_processors` (events-processor/Dockerfile:24). The public Helm chart
  (github.com/getlago/lago-helm-charts @d473b1e, 2026-08-18, external, read-only) deploys it only when
  ClickHouse is enabled, with `replicas: 1`, `ENV=production`, no probes, no
  `terminationGracePeriodSeconds` (Kubernetes default 30 s),
  `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` = `eventsProcessor.databasePool` (default 10), and
  without `LAGO_REDIS_STORE_TLS` or `LAGO_USE_MEMORY_CACHE`. With `ENV=production` the Redis store TLS default is ON
  (main_processor.go:84-91). Whether Lago's own production uses this chart: UNVERIFIED.

## 7. connectors/ (Redpanda Connect pipelines; not runnable from this repo as shipped)

`connectors/Dockerfile` = `docker.io/redpandadata/connect:4.83.0` + `*.yml`; built only to a private
ECR (`.github/workflows/build-connectors-image.yaml`). No public image, no run instructions.

| Pipeline | Input | Output | Notes |
|---|---|---|---|
| `http.yml` | `http_server` 0.0.0.0:3000 `POST /events`, no auth (:2-7) | raw topic `${KAFKA_TOPIC}`, key `org-ext_sub`, SASL SCRAM-SHA-512 hard-coded (:47) | `organization_id` taken from the request body (:25) |
| `sqs.yml` | SQS `${SQS_ENDPOINT}` | raw topic, TLS hard-coded true (:47); errored → SQS DLQ if `SQS_DLQ_ENDPOINT` set | org from `${ORGANIZATION_ID}` |
| `kinesis.yml` | Kinesis `${KINESIS_STREAM}`, DynamoDB checkpoints, `start_from_oldest` | raw topic | org from `${ORGANIZATION_ID}` (missing from README table) |

All three pass a JSON-number `precise_total_amount_cents` through and turn ANY non-number (string or
absent) into `"0"` (http.yml:32-36, kinesis.yml:38-43, sqs.yml:34-39). The Go
`Event.PreciseTotalAmountCents` is a `string` (events-processor/models/event.go:18): number records fail
`json.Unmarshal` in the events-processor and are committed without a DLQ entry (Sentry + log only). There
is no value-preserving workaround through the connectors ("send it as a string" only helps direct
producers); the fix is `event-accounting-campaign` W2. They also set `ingested_at = timestamp_unix()`
(integer seconds, http.yml:31), which ClickHouse reads as milliseconds (1970-01-2x): `rails-go-parity`. A run command would look like
`docker run --rm -e KAFKA_BROKERS=... -v "$PWD/connectors/http.yml:/connect.yaml" docker.io/redpandadata/connect:4.83.0 run /connect.yaml`
(UNVERIFIED: image entrypoint not inspected).

## 8. examples/agentic-ai-demo (maintained; README-linked)

`run.sh` checks docker/curl/jq and the daemon (run.sh:45-55), derives `LAGO_VERSION` from the root
compose api tag (run.sh:57; gives `v1.53.0` today; compose fallback `v1.51.0`, compose.yml:3), starts the
all-in-one image as project `lago-agentic-ai-demo` on 127.0.0.1:8080 (UI) / 127.0.0.1:3001 (API), then
`seed-and-verify.sh`. Demo credentials and API key are hard-coded for this disposable stack
(compose.yml:5-9). `run.sh --cleanup` removes containers, network and the data volume. It inherits all
all-in-one caveats above (PDF and Segment disabled in compose.yml:13-14).
