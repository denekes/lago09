# events-processor environment variables (complete registry)

Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only commits
on top. Verified 2026-10-01: every row was re-read in code; rows marked "probe" were also executed (scratch
programs against the real `utils` / `config/redis` packages, or the built binary under `env -i`).

Re-derive the list at any time:

```bash
cd "$(git rev-parse --show-toplevel)"
grep -rn 'Getenv\|GetEnv\|LookupEnv' --include=*.go events-processor | grep -v _test.go
.claude/skills/config-and-flags/scripts/env-crossref.sh --matrix-only --filter '.' | awk '$2=="R"||$2=="d"'
```

Expected: 29 names read at runtime (`R`) + 4 dead constants (`d`). There is **no dotenv loader**
(`grep -rn dotenv events-processor` is empty): the process sees only its real environment.

## 1. Parse helpers (`events-processor/utils/env.go`) — probe-verified truth table

| Helper | Code | unset | `""` | `"true"`/`"1"`/`"True"`/`"t"` | `"false"`/`"0"`/`"False"` | `"yes"`/`"no"`/`"on"`/`" true"` |
|---|---|---|---|---|---|---|
| `GetEnvAsBool(k, def)` | `utils/env.go:35-43` (`strconv.ParseBool`, error -> def) | def | def | true | false | **def** (silently) |
| `os.Getenv(k) == "true"` | e.g. `main.go:67` | false | false | only exact `true` | false | false |
| `GetEnvAsInt(k, def)` | `utils/env.go:9-20` (`strconv.Atoi`) | def, nil | def, nil | — | — | `"abc"`, `" 5"`, `"5.0"` -> def + **error** (callers panic) |
| `GetEnvOrDefault(k, def)` | `utils/env.go:45-52` | def | def | value | value | value |
| `ParseBrokersEnv(s)` | `utils/env.go:22-33` | `[]` | `[]` | — | — | `"a:9092, b:9092"` -> `["a:9092","b:9092"]`; `" "` -> `[""]` (len 1, passes the empty check) |

Consequence: `LAGO_REDIS_STORE_TLS=no` with `ENV=production` means TLS **on** (unparsable -> default
`true`). Always write `true`/`false` for Go booleans.

## 2. Master table

Class legend: **PIPE** = required by the event pipeline in any deployment · **TUNE** = optional tuning ·
**OBS** = optional observability · **PROD** = production setting (production runs memory-cache mode:
DECIDED OD-1 (owner, 2026-10-02)) · **DEPR** = deprecated behaviour · **DEAD** = declared, never read. "Dev" = value in
`.env.development.default` (DEF line).

| Variable | Default when unset / `""` | Required? (failure) | Parse | Effect | Read at | Dev (DEF) | Class |
|---|---|---|---|---|---|---|---|
| `LAGO_KAFKA_BOOTSTRAP_SERVERS` | none | YES: `panic: brokers not found` (probe, exit 2) | `ParseBrokersEnv` (main path); **raw string, not split** for CDC consumers | seed brokers for main consumer + 3 producers; CDC consumers get the unsplit string | `processors/main_processor.go:103-107`; `cache/consumer.go:28-31` | `redpanda:9092` (:77) | PIPE |
| `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC` | none | YES: `panic: LAGO_KAFKA_ENRICHED_EVENTS_TOPIC variable is required` (probe) | raw | enriched-events producer; producer `Ping`s the broker at start | `main_processor.go:32,118` -> `initProducer` `:55-75` | `events_enriched` (:79) | PIPE, cross-repo (ClickHouse DDL) |
| `LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC` | none | YES (same message pattern) | raw | in-advance producer; consumed by lago-api Karafka (`$API/karafka.rb:49-52`) | `main_processor.go:33,123` | `events_charged_in_advance` (:85) | PIPE, cross-repo |
| `LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC` | none | YES (same message pattern) | raw | DLQ producer; ClickHouse ingests it (`$API/db/clickhouse_migrate/20251110130723_create_events_dead_letter_queue.rb:9`) | `main_processor.go:34,128` | `events_dead_letter` (:86) | PIPE, cross-repo |
| `LAGO_KAFKA_RAW_EVENTS_TOPIC` | `""` — **not validated** | effectively yes (consumer of topic `""`; runtime behaviour UNVERIFIED) | raw | topic consumed; also part of the group name | `main_processor.go:36,171` | `events-raw` (:78, hyphen) | PIPE, cross-repo |
| `LAGO_KAFKA_CONSUMER_GROUP` | `""` — not validated | no (group becomes `_<topic>`) | raw | consumer group = `<LAGO_KAFKA_CONSUMER_GROUP>_<topic>`; a NEW group starts at the earliest offset, so renaming either part replays the retained raw topic | `main_processor.go:31,172`; `config/kafka/consumer.go:237` | `lago_dev` (:90) | PIPE |
| `LAGO_KAFKA_SCRAM_ALGORITHM` | `""` -> no SASL | no | exact match `SCRAM-SHA-256` / `SCRAM-SHA-512` | any other non-empty value appends a nil `kgo.Opt` -> **SIGSEGV** in `kgo.validateCfg` (probe) | `main_processor.go:37,110`; `config/kafka/kafka.go:48-64` | `""` (:81) | PIPE when broker needs auth (main consumer + producers only: the cache-mode CDC consumers never get it, `cache/consumer.go:30-35`) |
| `LAGO_KAFKA_TLS` | false | no | `GetEnvAsBool` | `kgo.DialTLS()` with default `tls.Config` (system roots, verification on) | `main_processor.go:38,111`; `kafka.go:66-69` | `""` (:82) | PIPE when broker needs TLS (not applied to the CDC consumers either) |
| `LAGO_KAFKA_USERNAME` | `""` | only with SCRAM | raw | SCRAM user | `main_processor.go:39,114`; `kafka.go:51-54` | `""` (:83) | PIPE (auth) |
| `LAGO_KAFKA_PASSWORD` | `""` | only with SCRAM | raw | SCRAM password | `main_processor.go:35,115` | `""` (:84) | PIPE (auth) |
| `DATABASE_URL` | `""` -> pgx falls back to libpq `PG*` env and defaults (probe: `host=/var/run/postgresql`, user = OS user) | YES in both modes (connect failure -> `panic` "Error connecting to the database") | `pgxpool.ParseConfig` (`config/database/database.go:25`) | DB mode: lookups pool; cache mode: initial snapshot only (pool size hard-coded 10) | DB mode `main_processor.go:140` (only if `config.Cache == nil`, `:133`); cache mode `cache/cache.go:65-66` | `postgresql://${POSTGRES_USER}:...@db:5432/${POSTGRES_DB}` (:24, interpolated) | PIPE |
| `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` | 200 | no | `GetEnvAsInt` | DB-mode pool size (pgxpool `MaxConns`, `config/database/database.go:24-33`). Junk -> `panic` "Error converting max connections into integer"; `0`/negative -> pgxpool `MaxSize must be >= 1` (probe) -> panic. Larger than the database allows -> silent loss under a burst: sizing rule in section 2a | `main_processor.go:29,134-137` | `200` (:33) | TUNE, DB mode only: dev, the bare binary, and the public Helm chart (`eventsProcessor.databasePool`, default 10; it never sets `LAGO_USE_MEMORY_CACHE`). Production runs cache mode (DECIDED OD-1), which ignores it |
| `LAGO_REDIS_STORE_URL` | `""` -> go-redis default `localhost:6379` (`go-redis/v9@v9.17.1/options.go:273-275`) | YES unless a Redis answers on localhost:6379 (`Ping` at start, `config/redis/redis.go:50-53`; failure -> `panic` "Error connecting to the flag store") | raw, then `^rediss?://` stripped (`redis.go:25-28`) | flag store: ZADD `subscription_refreshed_v2` (consumed by `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb`) | `main_processor.go:46,88` | `redis:6379` (:34) | PIPE, cross-repo |
| `LAGO_REDIS_STORE_PASSWORD` | `""` | if Redis requires AUTH | raw | AUTH password | `main_processor.go:45,89` | `""` (:35) | PIPE |
| `LAGO_REDIS_STORE_DB` | 0 | no | `GetEnvAsInt`; junk -> error -> panic "Error connecting to the flag store" | logical DB; MUST equal lago-api's `LAGO_REDIS_STORE_DB` (`$API/...consume_subscription_refreshed_queue_service.rb:61`) | `main_processor.go:44,79-82` | `1` (:36) | PIPE, cross-repo |
| `LAGO_REDIS_STORE_TLS` | **`ENV == "production"`** | no | `GetEnvAsBool(…, legacyTLS)` | TLS with `InsecureSkipVerify: true` always (`redis.go:42-46`) | `main_processor.go:47,85,91` | not set | PIPE; the `ENV` fallback is DEPR (code comment `:84`); `events-processor/README.md:56` says "default: false" (stale) |
| `ENV` | `development` | no | `GetEnvOrDefault` / `os.Getenv` | `development` -> DEBUG log level, else INFO (`main.go:31-36`); Sentry environment (`main.go:55`); tracer env tag (`config/tracing/tracer.go:105-108`); `production` -> Redis-store TLS default on | `main.go:21,31`; `main_processor.go:28,85`; `tracer.go:25,105` | not set (dev runs DEBUG) | OBS + DEPR coupling |
| `SENTRY_DSN` | `""` -> Sentry disabled | no | raw | error reporting (the ONLY sink for some failures, see `architecture-contract`) | `main.go:22,54` | not set | OBS |
| `TRACING_PROVIDER` | `""` -> auto-detect: `DD_TRACE_ENABLED`, then `OTEL_EXPORTER_OTLP_ENDPOINT`, else none | no | exact `datadog` / `opentelemetry` | selects tracer provider | `tracer.go:26,47,87-102` | not set | OBS |
| `DD_TRACE_ENABLED` | false | no | `GetEnvAsBool` | auto-selects Datadog | `tracer.go:35,94` | not set | OBS |
| `DD_AGENT_HOST` | `""` | no | raw | agent address `host:port` (`:8126` if host empty) | `tracer.go:36,137-139` | not set | OBS |
| `DD_TRACE_AGENT_PORT` | `8126` | no | `GetEnvOrDefault` | agent port | `tracer.go:37,138` | not set | OBS |
| `DD_SERVICE_NAME` | `lago-events-processor` | no | raw, empty -> default | service name | `tracer.go:38,132-135` | not set | OBS |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `""` | no | raw; non-empty also auto-selects OTel | OTLP gRPC endpoint (traces + metrics) | `tracer.go:30,97,126`; `otel_tracer.go:229,247` | not set | OBS |
| `OTEL_INSECURE` | false (TLS on) | no | `GetEnvAsBool` | `SecureMode = !insecure` | `tracer.go:31,128-129` | not set | OBS |
| `OTEL_SERVICE_NAME` | `lago-events-processor` | no | raw, empty -> default | service name | `tracer.go:32,122-125` | not set | OBS |
| `KAFKA_TRACING_ENABLED` | false | no | `GetEnvAsBool` | adds franz-go hooks **only if** the provider returns hooks (Datadog, OTel; the empty provider returns none, `empty_tracer.go:46`); main consumer + producers only, never the CDC consumers | `tracer.go:27,117`; `config/kafka/kafka.go:40-46` | not set | OBS (default off) |
| `LAGO_USE_MEMORY_CACHE` | off | no | **exact `== "true"`** (`True`, `1` = off) | in-memory Badger cache: DB snapshot (`cache.LoadInitialSnapshot`) + Debezium CDC consumers, started in `main.go:67-80` BEFORE the main pipeline | `main.go:23,67` | not set (dev = DB mode) | **PROD (`true`)**: DECIDED OD-1 (owner, 2026-10-02); production CDC config (Debezium column list, SASL/TLS, brokers) is OPEN DECISION OD-1b (owner) |
| `LAGO_DEBEZIUM_TOPIC_PREFIX` | `""` -> topics `.public.<table>` (no validation) | only in cache mode (not enforced) | raw | CDC topics = prefix + `.public.billable_metrics` / `subscriptions` / `charges` / `billable_metric_filters` / `charge_filters` / `charge_filter_values` (`cache/*.go:15-18` consts, `+ topic` at e.g. `cache/charges.go:61`) | `main.go:24,70` -> `cache/cache.go:50` | not set | PROD (required in cache mode; production value OPEN DECISION OD-1b (owner)) |
| `LAGO_REDIS_CACHE_URL`, `_PASSWORD`, `_DB`, `_TLS` | — | — | — | **never read** (constants only) since `2fd8e8b` (2026-09-14, "Stop expiring charge cache"); `events-processor/README.md:47,57-59` still documents them (`:47` as required) | `main_processor.go:40-43` | `LAGO_REDIS_CACHE_*` keys in DEF are for lago-api | DEAD |

Third-party libraries read their own variables too: pgx `PG*` (probe-verified for an empty
`DATABASE_URL`), sentry-go `SENTRY_*`, dd-trace-go `DD_*`, OpenTelemetry SDK `OTEL_*`. Those beyond the
rows above are UNVERIFIED (not enumerated).

## 2a. Sizing `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` (DB mode)

Rule: **pool × events-processor replicas + every other client of that database ≤ the database
budget.** The budget is the lowest of: `max_connections` minus the reserved slots
(`superuser_reserved_connections`, and `reserved_connections` on Postgres 16+), and any `CONNECTION LIMIT`
on the database or on the role in `DATABASE_URL`. Other clients: lago-api processes (`DATABASE_POOL`, default
10 per process at `$API/config/database.yml:89-99`; one pool per api, worker and clock process), pghero,
migrations, a Debezium slot.

Why it matters (EXECUTED, `events-processor-spec` EPC-30, reference binary of tree 83e012866f29):
- One poll returns up to 10,000 records (`config/kafka/consumer.go:168`) and each runs in its own goroutine,
  so a burst opens connections up to the pool cap at once.
- Above the budget Postgres refuses the extra connections (SQLSTATE 53300; exact texts: `debugging-playbook`
  entry `loss-db-connections`). Each refused lookup is a retryable failure, and a later commit skips it:
  pool 200 against a 30-connection limit lost 85-170 of a 201-record burst in nine kit runs (re-run 2026-10-02:
  170 of 201).
- Below the budget the pool cap queues lookups instead (pgxpool `MaxConns`, `config/database/database.go:24-33`).
  EPC-21 caps the pool at 20 and loses nothing in a 200-record burst. Under ADR-001 (DECIDED OD-2) exhaustion
  becomes a SYSTEMIC pause instead of loss (`reimplementation-kit` RBD-10); that is not built yet.

Defaults as of 2026-10-02:
- binary: 200 (`processors/main_processor.go:134`);
- dev: 200 (`.env.development.default:33`) against a dev Postgres `max_connections = 1000` (`scripts/postgresql.conf:15`), so dev is safe;
- public Helm chart (external, getlago/lago-helm-charts @d473b1e): `eventsProcessor.databasePool` = 10 (UNVERIFIED for any later chart version);
- stock Postgres (initdb default): `max_connections` 100, `superuser_reserved_connections` 3 (`psql postgres://lago:lago@localhost:5432/lago -Atc 'SHOW max_connections'` on the sandbox's Postgres 16 -> `100`). A bare binary at 200 against it can lose most of a burst.

Memory-cache mode (production) ignores this variable: it opens only a 10-connection pool for the startup
snapshot (`cache/cache.go:63-67`). Check a live database (prints no secret):
`psql "$DATABASE_URL" -c 'SHOW max_connections' -c 'SELECT datname, usename, count(*) FROM pg_stat_activity GROUP BY 1,2'`.

## 3. Startup checks (order of checks; only partially fail-fast)

The startup order, panic texts and captured outputs belong to `architecture-contract` section 2 (invariant I14
is PARTIAL; reproduce with its `startup-contract.sh`); symptom -> fix is `debugging-playbook` section 2. The config
view (binary built to scratch and run under `env -i`; exit code 2 = Go panic):

| Variable | Checked at startup | First failure |
|---|---|---|
| `LAGO_KAFKA_BOOTSTRAP_SERVERS` | empty only (`" "` passes, section 1) | `{"level":"ERROR","msg":"brokers not found"}` then `panic: brokers not found` (plain `panic`, no Sentry event; `processors/main_processor.go:103-107`) |
| `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC`, `..._EVENTS_CHARGED_IN_ADVANCE_TOPIC`, `..._EVENTS_DEAD_LETTER_TOPIC` | empty, in that order | `panic: <VAR> variable is required` (`main_processor.go:55-58,118-131`) |
| `LAGO_KAFKA_SCRAM_ALGORITHM` | no | any value other than `SCRAM-SHA-256`/`-512`: SIGSEGV in `kgo.validateCfg`, no log line, no Sentry (`config/kafka/kafka.go:48-64`) |
| `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS`, `LAGO_REDIS_STORE_DB` | integer parse | panic `Error converting max connections into integer` / `Error connecting to the flag store` (`main_processor.go:134-137`, `:78-82,152-156`) |

Not checked: `LAGO_KAFKA_RAW_EVENTS_TOPIC`, `LAGO_KAFKA_CONSUMER_GROUP`, `LAGO_DEBEZIUM_TOPIC_PREFIX` (empty
accepted; `main_processor.go:168-172`, `main.go:70`); cache-snapshot errors are swallowed (`main.go:77`, no return value);
`brokers not found` and the SCRAM SIGSEGV reach no Sentry. In cache mode the snapshot + CDC consumers start
before any Kafka check (`main.go:67-80`).

## 4. Running the binary on the host against the dev stack (not runnable here: no Docker daemon)

The process does not read `.env.development.default` by itself. Load it into the shell, then override the
container host names (dev advertises Redpanda's external listener as `localhost:19092` and publishes it,
`docker-compose.dev.yml:377-383`; Postgres `5432` `:53-54`, Redis `6379` `:77-78`):

```bash
set -a; . ./.env.development.default; set +a     # verified: exports 74 keys, interpolates DATABASE_URL
export LAGO_KAFKA_BOOTSTRAP_SERVERS=localhost:19092 \
       DATABASE_URL=postgresql://lago:changeme@localhost:5432/lago \
       LAGO_REDIS_STORE_URL=localhost:6379
```

Verified only that the `set -a` line exports the 74 keys with `DATABASE_URL` interpolated; the run
against a live stack is UNVERIFIED here. Build/CGO env: see `build-and-env`.

## 5. History notes that matter when you add or rename an EP variable

| Commit | What happened | Lesson |
|---|---|---|
| `f277b44` (2025-03-21, #495) | added `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNEXIONS` | — |
| `7421650` (2025-04-07, #500) | renamed it to `..._CONNECTIONS` with no fallback; added `LAGO_REDIS_STORE_*` (and moved the `api` gitlink in the same commit, see change-control N1) | a rename silently drops every deployed setting |
| `a918f60` (2025-10-29, #613) | `LAGO_REDIS_STORE_TLS` replaces `ENV==production` (kept as default) | keep the old behaviour as the default when replacing a coupling |
| `475761d`, `1f2d36e` (2025-11, #633, #641) | Datadog tracing vars + `KAFKA_TRACING_ENABLED` added in Go only | README and DEF were not updated. The same pattern of skipping DEF (also `a918f60`, `fff5858`, which did update the README) is why 14 EP reads are absent from DEF today (`env-crossref.sh` gap GAP1) |
| `fff5858` (2026-04-27, #639) | `LAGO_USE_MEMORY_CACHE`, `LAGO_DEBEZIUM_TOPIC_PREFIX` | the mode was never wired into DEF or compose, yet production runs it (DECIDED OD-1 (owner, 2026-10-02)): a production-only path has no dev default to test against |
| `2fd8e8b` (2026-09-14, #766) | last reader of `LAGO_REDIS_CACHE_*` removed | constants and README rows left behind (DEAD) |
