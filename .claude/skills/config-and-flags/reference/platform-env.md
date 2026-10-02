# Platform (wrapper-level) environment variables, per plane

Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only commits
on top. lago-api facts at the pin `591ae90` (2026-09-08, `$API`); verified 2026-10-01. Values are what the
**api container** receives after `docker compose config` with a CLEAN environment (`env -i`, no project
`.env` via `--env-file /dev/null`, `LAGO_DOMAIN` unset), so they are the shipped defaults. Consumers are
`$API/<path>:<line>` at the pinned SHA. Secrets policy is NOT covered here (see `security-and-supply-chain`); placeholders shown are
the literal strings committed in the repo.

Regenerate the value columns (daemon-less, read-only):

```bash
cd "$(git rev-parse --show-toplevel)"
for f in docker-compose.dev.yml docker-compose.yml deploy/docker-compose.{local,light,production}.yml; do
  echo "== $f"; env -i PATH="$PATH" HOME="$HOME" docker compose --env-file /dev/null -f "$f" config --format json 2>/dev/null \
    | jq -r '.services.api.environment | to_entries[]
             | "\(.key)=\(if (.key | test("SECRET|PASSWORD|TOKEN|LICENSE|SALT|_KEY$|_KEY_|DATABASE_URL")) then "(set; value not shown)" else .value end)"' | sort
done   # secret-bearing keys are masked (a git-ignored .env.development still feeds dev); section C cites their placeholders by file:line
API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)   # consumers: grep -rn 'ENV\["NAME"' "$API"
```

Column legend: **DEV** = `docker-compose.dev.yml` api (env_file `.env.development.default` = "DEF" + its
own `environment:`), **ROOT** = `docker-compose.yml` (anchor `x-backend-environment`, lines 20-73),
**LOC/LIT/PRD** = `deploy/docker-compose.{local,light,production}.yml`, **RUN** = `docker/runner.sh`
default map (single image). `–` = not passed at all. `""` = passed **set but empty** (Ruby sees `""`, not
nil: see SKILL.md section 5). Line refs: `DEF:n` = `.env.development.default`, `root:n`, `loc:n`,
`lit:n`, `prd:n`, `run:n`.

## A. URLs and hosts

| Variable | DEV | ROOT | LOC | LIT | PRD | Defined at | Consumers | Presence notes |
|---|---|---|---|---|---|---|---|---|
| `LAGO_API_URL` | `https://api.lago.dev` | `http://localhost:3000` | same | `https:///api` | `https:///api` | DEF:1 root:16 loc:19 lit:24 prd:24 run:17 | `$API/config/environments/production.rb:38` (ActionCable origins); 18 lago-api files read it | LIT/PRD derive it from `LAGO_DOMAIN`; unset domain renders an empty host (compose only warns) |
| `LAGO_FRONT_URL` | `https://app.lago.dev` | `http://localhost` | same | `https://` | `https://` | DEF:2 root:18 loc:21 lit:23 prd:23 run:16 | `$API/config/initializers/cors.rb:7-16` (`ENV.key?` wins over `LAGO_DOMAIN`), `$API/config/application.rb:31` | root `migrate` gets neither URL; `api-worker`/`api-clock` get only `LAGO_API_URL` (root:130,153,215,335) |
| `API_URL` (front) | front svc: `https://api.lago.dev` | `${LAGO_API_URL:-http://localhost:3000}` | same | `https://${LAGO_DOMAIN}` | same | root:75 loc:66 lit:70 prd:70 run:18 | lago-front `.env.sh:6` | LIT/PRD have no `/api` suffix (GraphQL routed by path) |
| `APP_ENV` (front) | – | `production` | same | same | same | root:76 | lago-front `.env.sh:8` | |
| `LAGO_DOMAIN` | – | – | – | interpolation only | interpolation only | lit:19 prd:20 (`x-lago-domain` anchor never merged) | `$API/config/initializers/cors.rb:17` fallback; lago-front `.env.sh:7` | the anchor is dead: api/front never receive `LAGO_DOMAIN` (`lit:21` `# TODO: Use only LAGO_DOMAIN`) |
| `LAGO_ACME_EMAIL` | – | – | – | Traefik flag | Traefik flag | `deploy/.env.*.example:2` | Traefik ACME resolver | |
| `LAGO_PDF_URL` | `http://pdf:3000` | `${…:-http://pdf:3000}` | `${…:-…}` | hard-coded | hard-coded | DEF:31 root:46 loc:49 lit:52 prd:52 run:19 (`http://host.docker.internal:3001`) | `$API/app/services/utils/pdf_generator.rb:34` | not overridable in LIT/PRD |
| `LAGO_OAUTH_PROXY_URL` | – | hard-coded `https://proxy.getlago.com` | same | same | same | root:56,77 | `$API/app/services/payment_providers/gocardless_service.rb:7`; front `.env.sh:9` | not overridable anywhere |

## B. Database and Redis

| Variable | DEV | ROOT | LOC/LIT/PRD | Defined at | Consumers | Notes |
|---|---|---|---|---|---|---|
| `DATABASE_URL` | `postgresql://lago:changeme@db:5432/lago` (interpolated from DEF:21-23) | built from `POSTGRES_*` + `?search_path=${POSTGRES_SCHEMA:-public}` | same pattern | DEF:24 root:21 loc:24 lit:27 prd:27 run:72 | `$API/config/database.yml:88-135` (staging/prod); dev section hard-codes host/user/pw (`database.yml:20-45`); EP (see events-processor-env.md) | dev `migrate` also sets it in `environment:` (`docker-compose.dev.yml:155`), which beats env_file |
| `DATABASE_TEST_URL` | `…/lago_test` | – | – | `docker-compose.dev.yml:187` | `$API/config/database.yml:62-71` | dev only |
| `REDIS_URL` | `redis://redis:6379` | `redis://${REDIS_HOST:-redis}:${REDIS_PORT:-6379}` | same | DEF:25 root:22 loc:25 lit:28 prd:28 run:15 | `$API/lib/lago/redis_config_builder.rb:54` (Sidekiq, `VERIFY_NONE`), `$API/config/cable.yml` fallback | `rediss://` scheme = TLS for lago-api |
| `REDIS_PASSWORD` | – | `""` | `""` | root:23 loc:26 lit:29 prd:29 | `redis_config_builder.rb:66` (`.presence`) | bundled redis never runs `--requirepass` in root/deploy |
| `LAGO_REDIS_CACHE_URL` | `redis://redis:6379` | `redis://${LAGO_REDIS_CACHE_HOST:-redis}:${LAGO_REDIS_CACHE_PORT:-6379}` | same | DEF:28 root:49 loc:50 lit:53 prd:53 | `redis_config_builder.rb:74,95`; `$API/clock.rb:55` (gates wallet refresh) | always non-empty in ROOT/deploy, so the cache and wallet refresh are always ON there |
| `LAGO_REDIS_CACHE_PASSWORD` | `""` | `""` (root:50 has no `:-` -> compose warning) | `""` | DEF:29 root:50 loc:51 lit:54 prd:54 | `redis_config_builder.rb:86` | |
| `LAGO_REDIS_CACHE_DB` | `3` | – | – | DEF:30 | `$API/config/environments/development.rb:30` (dev only) | incident `3cd78f1`: EP once used DB 0 vs api DB 3 |
| `LAGO_REDIS_CABLE_URL` | – | `""` | `""` | root:51 loc:52 lit:55 prd:55 (added `36327d2`) | `$API/config/cable.yml:3,11,16` = `ENV.fetch("LAGO_REDIS_CABLE_URL", ENV.fetch("REDIS_URL", …))` | **trap**: `ENV.fetch` keeps `""`, so the `REDIS_URL` fallback is NOT used in ROOT/deploy (verified Ruby semantics). redis-client 0.26.3 (`$API/Gemfile.lock`) parses `""` as a unix-socket URL with an empty path (`RedisClient::URLConfig.new("")` -> path `""`, run against the gem source); the end-to-end effect on ActionCable is UNVERIFIED (CANDIDATE defect, cross-repo) |
| `LAGO_REDIS_SIDEKIQ_SENTINELS` / `_MASTER_NAME` | `""` / `""` | – | – | DEF:26-27 | `redis_config_builder.rb:63-64` (`.presence`; master default `master`) | dev profile `redis-sentinel` |
| `LAGO_REDIS_STORE_URL` / `_PASSWORD` / `_DB` | `redis:6379` / `""` / `1` | – | – | DEF:34-36 | EP writer; `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:17,48-67` reader; `$API/clock.rb:210` | ROOT/deploy run no events-processor, so the store is absent there |
| `POSTGRES_USER` / `_PASSWORD` / `_DB` | `lago` / `changeme` / `lago` (keys in DEF:21-23, also passed into every app container) | interpolation inputs + db container env | same | DEF:21-23 root:95-97 | db image; interpolated into `DATABASE_URL` | dev `db` takes them from shell/project `.env` (`${POSTGRES_PASSWORD:-changeme}`), NOT from `.env.development` |
| `POSTGRES_HOST` / `_PORT` / `_SCHEMA`, `REDIS_HOST` / `_PORT`, `LAGO_REDIS_CACHE_HOST` / `_PORT`, `LAGO_RAILS_STDOUT`, `API_PORT`, `FRONT_PORT` | – | interpolation only | interpolation only | root:21-22,26,49,157,172 | never reach the app under these names | `LAGO_RAILS_STDOUT` becomes `RAILS_LOG_TO_STDOUT` (`== "true"`, `$API/config/environments/production.rb:44`) |
| `DATABASE_POOL` | – | – | PRD workers only (= `SIDEKIQ_CONCURRENCY`) | prd:275,326,356,384,412,442 | `$API/config/database.yml` (`ENV.fetch('DATABASE_POOL', …)`) | |

## C. Secrets and keys (placeholders only; policy in `security-and-supply-chain`)

| Variable | DEV | ROOT/LOC/LIT/PRD | RUN | Consumers | Notes |
|---|---|---|---|---|---|
| `SECRET_KEY_BASE` | placeholder (DEF:71) | same placeholder default (root:24) | random per first boot (run:9) | `$API/app/services/utils/auth_token.rb:12,18` and 2 more | |
| `LAGO_ENCRYPTION_PRIMARY_KEY` / `_DETERMINISTIC_KEY` / `_KEY_DERIVATION_SALT` | `your-encrpytion-…` (typo, DEF:72-74) | `your-encryption-…` (root:29-31) | random (run:12-14) | `$API/config/application.rb:35-37` | unprefixed `ENCRYPTION_*` win via `||`, and an empty-but-set unprefixed var wins too (Ruby `"" || x` is `""`) |
| `LAGO_RSA_PRIVATE_KEY` | – (dev uses `config/keys/private.pem`) | ROOT `""` (root:27, no `:-` -> warning); deploy `""` | generated (run:10) | `$API/config/initializers/rsa_keys.rb:6-15`: file first, else `Base64.decode64(ENV)`, blank -> `abort` | single-line base64 |
| `LAGO_LICENSE` | `""` (DEF:64) | `""` | – | `$API/lib/lago_utils/lago_utils/license.rb:11-13` | a real value was on main 37 days (merge `0a67ac0` 2025-01-29 -> `6dd7e56` 2025-03-07; up to 43 days if the feature branch was public from 2025-01-23, UNVERIFIED); rotation OPEN DECISION OD-9 (owner); never print it |
| `LAGO_DATA_API_BEARER_TOKEN` | `changeme` (DEF:63) | ROOT `""`; deploy – | – | `$API/app/controllers/data_api/base_controller.rb:16` | |
| `SEGMENT_WRITE_KEY` | `""` (DEF:68) | – | – | `$API/config/initializers/analytics_ruby.rb:20` (`ENV.fetch(…, "changeme")`) | |
| `MISTRAL_API_KEY` / `MISTRAL_AGENT_ID` | `""` | ROOT `""`; deploy – | – | `$API/app/graphql/mutations/ai_conversations/create.rb:21` (blank -> forbidden) | ROOT-only (`3941b69` touched DEF + root only) |
| `NANGO_SECRET_KEY` | `""` (DEF:67; also dev `front` env `docker-compose.dev.yml:111`) | – | – | `$API/app/services/integrations/aggregator/base_service.rb:145` | the front reads `NANGO_PUBLIC_KEY`, so the front copy is dead |
| `GOOGLE_AUTH_CLIENT_ID` / `_SECRET` | `""` (dev compose :188-189) | `""` | – | `$API/app/services/auth/google_service.rb:160-178` | |

## D. Feature flags (classification and parsing in SKILL.md sections 4-5)

| Variable | DEV | ROOT | LOC/LIT/PRD | RUN/DEMO | Consumer + idiom |
|---|---|---|---|---|---|
| `LAGO_SIDEKIQ_WEB` | `true` | `true` | `true` | – | `$API/config/routes.rb:4`, `$API/config/initializers/sidekiq.rb:22` (`== "true"`); self-host default = OPEN DECISION OD-16 (owner, security) |
| `LAGO_CLICKHOUSE_ENABLED` | `true` | – | – | – | MIXED: `=false` leaves the 12 `.present?`/`.blank?` sites ON (incl. `$API/app/services/events/stores/store_factory.rb:10`) and turns OFF org creation (`Boolean.cast`, `$API/app/services/organizations/create_service.rb:17`) and the 2 `== "true"` seeds |
| `LAGO_CLICKHOUSE_MIGRATIONS_ENABLED` | `true` | – | – | – | `.present?` `$API/config/database.yml:56,82,111,148`; `== "true"` `$API/scripts/start.sh:10`, `$API/lib/tasks/lago.rake:12` |
| `LAGO_DISABLE_SEGMENT` | `true` | `""` (root:52, no `:-`) | `""` | DEMO `true` | `== "true"` `$API/config/initializers/analytics_ruby.rb:3` -> telemetry ON by default in ROOT/deploy |
| `LAGO_DISABLE_WALLET_REFRESH` | `true` | `""` | `""` | – | `== "true"` `$API/clock.rb:56` |
| `LAGO_DISABLE_PDF_GENERATION` | `false` (+ dev front `:110`) | `false` (back root:55 + front root:78) | **missing** | DEMO `true` | `Boolean.cast` `$API/app/services/invoices/generate_pdf_service.rb:100` (+3); front `.env.sh:13` |
| `LAGO_DISABLE_SIGNUP` | front only (`docker-compose.dev.yml:109`) | `false` (backend only) | `false` (backend only) | – | `ENV.fetch(…,"false") == "true"` `$API/app/services/users_service.rb:45`; front `.env.sh:10` — ROOT/deploy never pass it to the front |
| `LAGO_DISABLE_SSL` | – | – | – | RUN `true` (run:11) | `Boolean.cast` `$API/config/environments/production.rb:34` (`assume_ssl`) |
| `LAGO_USE_AWS_S3` (+ `LAGO_AWS_S3_*`) | `false` | `false` (keys placeholder `azerty123456`) | same | – | `.present? && == "true"` production/development; `.present?` only in `$API/config/environments/staging.rb:18` |
| `LAGO_USE_GCS` (+ `LAGO_GCS_PROJECT/BUCKET`) | – | `false` | same | – | `$API/config/environments/production.rb:22` |
| `LAGO_CREATE_ORG` (+ `LAGO_ORG_*`) | `true` | `false` | `false` | DEMO `true` | `.present? && == "true"` `$API/lib/tasks/signup.rake:6`; shell `== "true"` `$API/scripts/migrate.sh:14` |
| `LAGO_KARAFKA_WEB` / `_PROCESSING` / `_WEB_SECRET` | `""` | – | – | – | `if ENV[...]` `$API/config/routes.rb:8` (`""` mounts the route); `.present?` `$API/karafka.rb:66-70` |
| `LAGO_WEBHOOK_ATTEMPTS` | `1` | – | – | – | `ENV.fetch(…, 3).to_i` `$API/app/services/webhooks/send_http_service.rb:58` |
| `LAGO_PARALLEL_THREADS_COUNT` | `4` | – | – | – | `$API/app/services/invoices/preview_service.rb:205` |
| `LAGO_MCP_SERVER_URL` | `http://mcp-server:3001/mcp` | – | – | – | `$API/app/services/ai_conversations/stream_service.rb:76`; no compose file in THIS repo defines `mcp-server`; the getlago/lago-agent-toolkit overlay `mcp/docker-compose.dev.yml` does (port 3001, built from `LAGO_MCP_SERVER_PATH`): undocumented here (`docs-and-writing` SC-34) |
| `LAGO_DATA_API_URL` | `http://data_api` | `http://data-api` | – | – | `$API/app/services/data_api/base_service.rb:29`; no such service anywhere; host names differ (`_` vs `-`) |

## E. Event pipeline variables (dev plane only in this repo)

Set only in `.env.development.default:76-93` and `:33-36`. ROOT and deploy ship **no** events-processor,
Redpanda or ClickHouse, so none of these exist there. Production values live outside this repo
(UNVERIFIED). Production runs the events-processor in memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)); its
CDC settings (Debezium column list, Kafka auth, brokers) are OPEN DECISION OD-1b (owner).

| Variable | DEF | Readers |
|---|---|---|
| `LAGO_KAFKA_BOOTSTRAP_SERVERS` | `redpanda:9092` | EP (`main_processor.go:103`, `cache/consumer.go:28`); `$API/karafka.rb:10`; `$API/app/services/events/kafka_producer_service.rb:16`; gate in `$API/app/services/events/pay_in_advance_service.rb:67`; every CH `_queue` migration |
| `LAGO_KAFKA_RAW_EVENTS_TOPIC` | `events-raw` | API producer `kafka_producer_service.rb:17,31`; EP consumer; CH `20231026124912_create_events_raw_queue.rb:9` |
| `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC` | `events_enriched` | EP producer; CH `20240705084952_create_events_enriched_queue.rb:9` (the only functional lago-api read; `$API/lib/lago/diagnostics.rb:560` only displays it) |
| `LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC` | `events_charged_in_advance` | EP producer; `$API/karafka.rb:49-52` consumer (DLQ topic `unprocessed_events` hard-coded `:55`) |
| `LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC` | `events_dead_letter` | EP producer; CH `20251110130723_create_events_dead_letter_queue.rb:9` |
| `LAGO_KAFKA_ACTIVITY_LOGS_TOPIC` / `_API_LOGS_TOPIC` / `_SECURITY_LOGS_TOPIC` | `activity_logs` / `api_logs` / `security_logs` | `$API/app/services/utils/{activity_log,api_log,security_log}.rb`; CH `_queue` migrations |
| `LAGO_KAFKA_CLICKHOUSE_CONSUMER_GROUP` | `clickhouse` | CH `_queue` migrations only (baked into DDL) |
| `LAGO_KAFKA_CONSUMER_GROUP` | `lago_dev` | EP only (`events-processor/processors/main_processor.go:31,172`) |
| `LAGO_KAFKA_SCRAM_ALGORITHM` / `_TLS` | `""` / `""` | EP only (`events-processor/processors/main_processor.go:37-38`; lago-api uses other names, SKILL.md section 6) |
| `LAGO_KAFKA_USERNAME` / `_PASSWORD` | `""` | EP and `$API/karafka.rb:21-26` (shared names) |
| `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` | `200` | EP only (`events-processor/processors/main_processor.go:29,134`) |
| `LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC` | removed from DEF in `d9c32b6` | still read by `$API/db/clickhouse_migrate/20250814124830_create_events_enriched_expanded_queue.rb:9`: a fresh dev ClickHouse gets that queue table with an empty topic list (effect UNVERIFIED) |

ClickHouse connection settings (`LAGO_CLICKHOUSE_HOST/PORT/DATABASE/USERNAME/PASSWORD/SSL`) are read only in
`$API/config/database.yml:75-79,104-108,139-145` (test/staging/production); dev hard-codes
`clickhouse:8123` `default/default` (`database.yml:46-57`), matching `extra/clickhouse/users.d/users.xml`.

## F. Sidekiq routing and concurrency

| Variable | DEV | ROOT | LOC/LIT/PRD | Consumer |
|---|---|---|---|---|
| `SIDEKIQ_EVENTS/PDFS/BILLING/CLOCK/WEBHOOK/ANALYTICS/AI_AGENT` | `false` each (DEF:46-52) | commented hints only (root:67-73; no ANALYTICS hint, ALERTS is :73) | not set (PRD has dedicated worker services anyway) | `ActiveModel::Type::Boolean.new.cast` in `queue_as` blocks, e.g. `$API/app/jobs/bill_subscription_job.rb:5` |
| `SIDEKIQ_ALERTS` / `SIDEKIQ_PAYMENTS` / `SIDEKIQ_WALLETS` | – | ALERTS commented (root:73, `f2e202a`) | – | `$API/app/jobs/**` + `$API/app/services/usage_monitoring/process_organization_subscription_activities_service.rb:22` |
| `SIDEKIQ_CONCURRENCY` | dev shim from `SIDEKIQ_CONCURRENCY_<X>` | – | PRD per worker (prd:274,325,355,383,411,441) | `$API/config/sidekiq/*.yml` (`ENV.fetch('SIDEKIQ_CONCURRENCY', 10)`; production 5 for billing/clock/alerts) |
| `SIDEKIQ_CONCURRENCY_<X>` | `10` each (DEF:54-60) | – | – | only the dev shell shim (`docker-compose.dev.yml:225-294`); lago-api never reads these names |

Routing notes (moved from SKILL.md section 4):
- "on production, we rely on dedicated workers" (`docs/dev_environment.md:178`).
- The flag is read at ENQUEUE time (`queue_as`, e.g. `$API/app/jobs/bill_subscription_job.rb:5`), so set it on every process that enqueues (api, workers, clock), and
  run the worker for that queue, or jobs pile up in a queue nobody consumes.
- Uncommenting the root hints as written breaks YAML: the list item `- SIDEKIQ_EVENTS=true` sits inside the
  `x-backend-environment` mapping (VERIFIED 2026-10-01 in a scratch copy: `docker compose -f docker-compose.yml
  config --quiet` -> `did not find expected key`). Write `"SIDEKIQ_EVENTS": "true"` instead.

## G. lago-front start-up contract (pinned `0c5e539`)

`$FRONT/.env.sh:6-14` reads exactly: `API_URL LAGO_DOMAIN APP_ENV LAGO_OAUTH_PROXY_URL LAGO_DISABLE_SIGNUP
NANGO_PUBLIC_KEY SENTRY_DSN LAGO_DISABLE_PDF_GENERATION LAGO_SUPERSET_URL` (dev: the same set plus
`APP_VERSION` via vite `define`, `$FRONT/vite.config.ts:118-127`). The dev `front` service has **no env_file**: only its
`environment:` list (`docker-compose.dev.yml:104-111`), interpolated from the shell/project `.env`.
`FRONT=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh front)`.

## H. Single image (`docker/runner.sh`) precedence

1. `/data/.env` lines are exported unconditionally (`run:23-25`, `for LINE in $(cat …)`: values with spaces break).
2. Then every default-map key that is still EMPTY gets its default and is appended to `/data/.env` (`run:64-69`); `DATABASE_URL` likewise (`run:71-74`).

So: persisted `/data/.env` > `docker run -e` > runner default. A value passed with `-e` on a later boot
is ignored if `/data/.env` already holds that key. Generated secrets are persisted in plain text in the
data volume. `RAILS_ENV` is forced to `production` (`run:81`). The front gets its env through
`front/.env.sh` (`run:76-79`).

## I. Connectors (Redpanda Connect, `connectors/*.yml`)

<!-- evidence-check: off evidence = each column header names the file (connectors/<name>.yml); cells are its line numbers -->

| Variable | http.yml | sqs.yml | kinesis.yml | Default |
|---|---|---|---|---|
| `KAFKA_BROKERS`, `KAFKA_TOPIC`, `KAFKA_USER`, `KAFKA_PASSWORD` | :41,42,48,49 | :43,44,50,51 | :47,48,54,55 | none |
| `KAFKA_TLS` | :45 | **hard-coded `true`** :47 | :51 | `false` |
| `KAFKA_BATCH_COUNT` / `_BYTE_SIZE` / `_PERIOD` | :51-53 | – | :57-59 | `100` / `1000000` / `1s` |
| `ORGANIZATION_ID` | – (taken from the request body, :25) | :27,45 | :31 | none |
| `SQS_ENDPOINT/REGION/KEY_ID/KEY_SECRET/DLQ_ENDPOINT` | – | :4-9,54-58 | – | none |
| `KINESIS_STREAM`, `AWS_REGION`, `AWS_ROLE`, `AWS_ROLE_EXTERNAL_ID`, `DYNAMODB_TABLE` | – | – | :3-17 | none |

<!-- evidence-check: on -->

SASL mechanism is hard-coded `SCRAM-SHA-512` in all three. `connectors/README.md` omits `ORGANIZATION_ID`
from the Kinesis table although `kinesis.yml:31` needs it, and documents `LOG_LEVEL`, which no
pipeline file references. Redpanda Connect `${VAR:default}` syntax, not compose syntax.

## J. `deploy/.env.*.example`

`deploy/.env.light.example`: `LAGO_DOMAIN`, `LAGO_ACME_EMAIL`. `deploy/.env.production.example`: the same
plus `PORTAINER_USER`, `PORTAINER_PASSWORD` (mapped to `ADMIN_USER`/`ADMIN_PASSWORD` on the portainer
service). Nothing else (no `SECRET_KEY_BASE`, no encryption keys).

## K. lago-api knobs no wrapper plane passes (gap GAP5 of env-crossref.sh)

48 `LAGO_*` names as of 2026-10-01, e.g. `LAGO_CLICKHOUSE_HOST`, `LAGO_KAFKA_SASL_MECHANISMS`,
`LAGO_KAFKA_SECURITY_PROTOCOL`, `LAGO_REDIS_STORE_SSL`, `LAGO_REDIS_STORE_DISABLE_SSL_VERIFY`,
`LAGO_WALLET_ONGOING_BALANCE_REFRESH_INTERVAL_SECONDS`, `LAGO_DISABLE_EVENTS_VALIDATION`,
`LAGO_DEDICATED_WORKER_ORG_IDS`, `LAGO_LOG_LEVEL`, `LAGO_SMTP_DOMAIN`, `LAGO_WEBHOOK_TIMEOUT_SECONDS`.
In ROOT/deploy they cannot be set from `.env`: an anchor passes only the keys it lists, so you must add the
key to `x-backend-environment` (checklist in SKILL.md section 8). Full list:
`.claude/skills/config-and-flags/scripts/env-crossref.sh --gaps-only`.
