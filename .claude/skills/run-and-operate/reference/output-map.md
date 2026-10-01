# What output lands where

Read when you need to know where a component writes (topics, consumer groups, Redis keys, Postgres
tables, ClickHouse tables, logs, Sentry, DLQ, volumes, ports/hosts) or where to look for something.
Topic names below are the dev defaults from `.env.development.default:77-90`; self-host compose files
(root, deploy/, all-in-one) run NO Kafka, ClickHouse or events-processor at all. `$API` = pinned lago-api
checkout (`.claude/skills/research-methodology/scripts/pinned-checkout.sh api`, 591ae90).
Verified 2026-10-01; code facts as of 5308258 (events-processor tree 83e012866f29).

## 1. Kafka / Redpanda topics (dev: created by `redpandacreatetopics`, docker-compose.dev.yml:398-405)

| Topic (env var) | Producer(s) | Consumer(s) and group | Payload / key |
|---|---|---|---|
| `events-raw` (`LAGO_KAFKA_RAW_EVENTS_TOPIC`; hyphen, unlike the others) | lago-api `Events::KafkaProducerService` on every POST /events when bootstrap + topic env are set (`$API/app/services/events/kafka_producer_service.rb:15-34`), `Events::Stores::Clickhouse::ReEnrichSubscriptionEventsService` (rake `events:reprocess`); connectors | events-processor group `<LAGO_KAFKA_CONSUMER_GROUP>_<topic>` = `lago_dev_events-raw` (config/kafka/consumer.go:237); ClickHouse `events_raw_queue` group `LAGO_KAFKA_CLICKHOUSE_CONSUMER_GROUP` = `clickhouse` | raw event JSON, `source: "http_ruby"`; Rails sets no key; connectors key `org-ext_sub` |
| `events_enriched` | events-processor (every enriched event, including events with no subscription) | ClickHouse `events_enriched_queue` → MV → `events_enriched` | `models.EnrichedEvent` JSON; key `<org_id>-<transaction_id>` (event_producer_service.go:30) |
| `events_charged_in_advance` | events-processor when subscription found, not `api_post_processed`, plan has a pay-in-advance charge for the metric | lago-api Karafka consumer group `lago_events_charged_in_advance_consumer` (`$API/karafka.rb:49-56`) → `Events::PayInAdvanceJob` (delayed by the CH merge delay) | same EnrichedEvent JSON; same key (:41) |
| `events_dead_letter` | events-processor (non-retryable failure, retryable failure older than 12 h of `ingested_at`, failed enriched/in-advance produce) | ClickHouse `events_dead_letter_queue` → MV → `events_dead_letter` only. Nothing in lago-api reads it back (only the model `$API/app/models/clickhouse/events_dead_letter.rb`) | `models.FailedEvent` `{event, initial_error_message, error_message, error_code, failed_at}`; no key |
| `unprocessed_events` | Karafka DLQ for the in-advance consumer (`max_retries: 1`, karafka.rb:55) | nobody | NOT in the create-topics list; auto-creation by Redpanda UNVERIFIED |
| `activity_logs`, `api_logs`, `security_logs` | lago-api `Utils::ActivityLog`, `ApiLog`, `SecurityLog`, `EmailActivityLog` (need ClickHouse enabled) | ClickHouse `*_queue` tables, group `clickhouse` | JSON |
| `<prefix>.public.<table>` (memory-cache mode only, OPEN DECISION OD-1 (owner)) | Debezium connector (config `extra/debezium_config.json`, prefix `lago_proc_cdc`, slot `lago_dbz_evt_proc`; registration is manual and undocumented) | events-processor cache consumers, group `lago_evp_<model>_<uuid>` NEW on every start (cache/consumer.go:27) | Debezium unwrapped rows |
| `events_enriched_expanded` | nobody since `d9c32b6` (topic + env removed from dev) | lago-api CH migration `20250814124830` still builds a Kafka table from `LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC` | effect on a fresh dev ClickHouse: UNVERIFIED (see `rails-go-parity`) |

Kafka Connect itself (`redpanda-kafka-connect`) stores state in `_connectors_offsets`,
`_connectors_configs`, `_connectors_status` (docker-compose.dev.yml:443-452).

## 2. Redis

| Key / DB | Writer | Reader | Notes |
|---|---|---|---|
| ZSET `subscription_refreshed_v2` in `LAGO_REDIS_STORE_URL` / DB `LAGO_REDIS_STORE_DB` (dev `redis:6379` DB 1) | events-processor `ZADD <now> "<org>:<sub>|<10s bucket>"` (models/stores.go:54-69) | lago-api clock job `ConsumeSubscriptionRefreshedQueueJob`, only when `LAGO_REDIS_STORE_URL` AND `LAGO_CLICKHOUSE_ENABLED` are present (`$API/clock.rb:210-212`); `ZRANGEBYSCORE` + `ZREM` (`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:27,37`) | cross-repo contract (change-control N6). No TTL |
| Sidekiq queues | lago-api (`REDIS_URL`) | Sidekiq workers | |
| Rails cache (`LAGO_REDIS_CACHE_URL`, dev DB 3) | lago-api | lago-api | events-processor no longer reads `LAGO_REDIS_CACHE_*` (dead constants main_processor.go:40-43) |
| ActionCable | `LAGO_REDIS_CABLE_URL` or `REDIS_URL` | lago-api | |

## 3. Postgres

| Variant | Databases | Who writes | Notes |
|---|---|---|---|
| dev | `lago`, `lago_test` (`POSTGRES_MULTIPLE_DATABASES`, created by `scripts/pg-init-scripts` ONLY on an empty volume) | lago-api (migrate, api, workers) | `wal_level=logical`, `pg_partman_bgw` preloaded via `scripts/postgresql.conf:44,81-88` |
| root / deploy | `lago` (`POSTGRES_DB`), schema `public` (`search_path` in DATABASE_URL) | lago-api | |
| all-in-one | `lago` in the container's local Postgres 17 | lago-api | data location UNVERIFIED (variants.md §5) |

The events-processor NEVER writes Postgres. DB mode reads `billable_metrics`, `subscriptions`, `charges`
per event (pgx pool, `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS`, default 200); memory-cache mode
snapshots those plus `billable_metric_filters`, `charge_filters`, `charge_filter_values` at start (pool 10).
`public.enriched_events` (Postgres, partitioned when pg_partman is available) is written by lago-api
`Events::PostProcessService#create_enriched_events` only for orgs with feature flag
`postgres_enriched_events` (`$API/app/services/events/post_process_service.rb:94-99`; flags live in
`organizations.feature_flags`, default empty).

## 4. ClickHouse (dev only; database `default`, user `default`/`default`, native port 9000 published)

Created by lago-api ClickHouse migrations (`$API/db/clickhouse_migrate/`, run when
`LAGO_CLICKHOUSE_MIGRATIONS_ENABLED` is present). Each source topic has `<x>_queue` (Kafka engine; broker
list and topic are baked into the DDL from ENV at migration time) → `<x>_mv` → `<x>`.

| Table | Engine / key | Source topic |
|---|---|---|
| `events_raw` | `MergeTree` ORDER BY (org, ext_sub, code, transaction_id, timestamp) | `events-raw` |
| `events_enriched` | `ReplacingMergeTree(timestamp)`, ORDER BY (org, code, ext_sub, toDate(timestamp), timestamp, transaction_id); `decimal_value Decimal(38,26) DEFAULT toDecimal128OrZero(value, 26)` | `events_enriched` |
| `events_dead_letter` | `MergeTree` ORDER BY (org, ext_sub, code, transaction_id, timestamp, ingested_at); columns `event` (JSON), `error_code`, `error_message`, `initial_error_message`, `failed_at` | `events_dead_letter` |
| `activity_logs`, `api_logs`, `security_logs` | MergeTree families | same-name topics |

Duplicates: re-emitted enriched rows with the same ORDER BY key collapse only at merge time
(ReplacingMergeTree); billing reads them with `FINAL` only for orgs with `clickhouse_deduplication_enabled`
(default false; `$API/app/services/billable_metrics/aggregations/base_service.rb:161-169`;
`architecture-contract` I12), so before a merge duplicates can double-count. DLQ rows never collapse
(MergeTree).

## 5. Logs and error reporting

| Component | Where | Format |
|---|---|---|
| events-processor | stdout | JSON slog, `service=post_process`; DEBUG when `ENV` is unset or `development` (main.go:31-41), INFO otherwise; tags `component=kafka` / `kafka-producer` / `db`, `kafka-topic-consumer=<topic>`, `pkg=cache`. Triage: `debugging-playbook` |
| lago-api (all roles) | stdout when `RAILS_LOG_TO_STDOUT=true` (compose sets it via `LAGO_RAILS_STDOUT`, default true) | Rails logger; level `LAGO_LOG_LEVEL` (not passed by any compose file) |
| all-in-one | stdout (foreman) + `/data/db.log` (create/migrate/seed) | |
| Traefik dev | stdout | `traefik/traefik.yml:1-2` says `logs: level: debug`, but Traefik's static key is `log` (singular), so the debug level probably never applies (unchanged since `5e9b9bb`; UNVERIFIED: Traefik not run here) |
| gotenberg dev | `--log-level=debug` | |

Sentry: events-processor `SENTRY_DSN` (main.go:53-64; captures per-event failures WITH the full event,
customer `properties` included), lago-api `SENTRY_DSN` (`$API/config/initializers/sentry.rb:3`). No
compose file passes `SENTRY_DSN`: in dev put it in `.env.development` (env_file reaches every service);
root/deploy need a compose edit (anchors list only known keys). PII handling: `security-and-supply-chain`.

## 6. Volumes and persistent paths

| Variant | Volume (resolved name) | Mounted at |
|---|---|---|
| root | `<dir>_lago_postgres_data`, `<dir>_lago_redis_data`, `<dir>_lago_storage_data` | `/data/postgres`, `/data`, `/app/storage` (api, api-worker) |
| dev | `lago_dev_postgres_data_dev`, `lago_dev_redis_data_dev`, `lago_dev_redpanda_data_dev`, `lago_dev_clickhouse_data_dev`, `lago_dev_front_node_modules_dev`, `lago_dev_front_dist_dev`, `lago_dev_redis_replica_data_dev`, EXTERNAL `lago_front_pnpm_store` | |
| deploy/<v> | `lago-<v>_lago_postgres_data`, `_lago_redis_data`, `_lago_storage_data`, `_lago_rsa_data` (`/app/config/keys/private.pem`), production `_portainer_data`; light/production also bind `./letsencrypt` (acme.json) | |
| all-in-one | `/data` (declared VOLUME): `.env` with generated secrets in plaintext, `db.log` | |
| demo | `lago-agentic-ai-demo_data` | `/data` |

## 7. Ports and hostnames

| Variant | Host ports | Hostnames |
|---|---|---|
| dev | 80, 443 (traefik), 5432, 6379, 9000 (ClickHouse native), 9092 + 19092 (Redpanda internal/external listener), 8083 (Kafka Connect) | `api app console mail pdf pghero traefik webhook` `.lago.dev` (Traefik `Host()` rules; `api.lago.dev` also on plain `web`) |
| root | 3000 (api), 80 (front), 5432, 6379 | none |
| deploy/local | 3000, 80, 5432*, 6379* (* with the profiles that include db/redis) | none |
| deploy/light, production | 443 (Traefik), 8080 (Traefik dashboard, insecure), 5432*, 6379* | `Host(${LAGO_DOMAIN})`: front at `/`, api at `/api/` (prefix stripped) and `/api/v`, `/rails`, `/graphql`; production `/portainer` |
| all-in-one | 80, 3000 (+3001 for the `lago-pdf` sidecar) | none |
| demo | 127.0.0.1:8080, 127.0.0.1:3001 | none |
| connectors http | 3000 inside the container (`/events`) | none |

Health endpoints: lago-api `/health` (touches the DB) and `/ready` (`$API/config/routes.rb:16-17`);
Sidekiq processes answer a liveness TCP server on 8080 inside the container (`$API/config/initializers/sidekiq.rb:16,73-75`;
the compose healthchecks `curl -f http://localhost:8080`). The events-processor has none.
