---
name: config-and-flags
description: "Registry of every configuration axis in the Lago umbrella repo: config planes (.env.development.default, compose anchors, deploy/*.yml, docker/runner.sh, connectors, events-processor os.Getenv, lago-api ENV), precedence, defaults, prod vs dev flags, boolean-parsing traps, divergent TLS names, the add-a-variable checklist. Use when a variable does nothing, \"LAGO_CLICKHOUSE_ENABLED=false\", adding, renaming or removing an env var, LAGO_USE_MEMORY_CACHE, LAGO_REDIS_STORE_TLS vs _SSL, rediss://. Not for starting services (use run-and-operate) or secrets policy (use security-and-supply-chain)."
---
# Configuration and feature flags

Which variable is read by whom, with what default, parsed how, in which plane, and how to add one
without creating drift. Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch
may carry skills-only commits on top. lago-api facts are at the pin `591ae90` (2026-09-08). Verified
2026-10-01 unless marked; owner decisions OD-1..OD-5 of 2026-10-02 folded in (register: `change-control` §9).

## When to use / when NOT to use

Use when you:
- set, add, rename or remove an environment variable anywhere (dev, self-host, deploy, single image, events-processor);
- see a flag that "does nothing" or behaves inverted, an empty value that still enables something, or `=false` that turns a feature ON;
- wire Kafka/Redis auth or TLS, or change a Kafka topic or consumer-group name;
- need the default of a variable in a given plane, or which code reads it.

Do NOT use for:
- starting/stopping stacks, volumes, what output lands where -> `run-and-operate`;
- whether a default is safe to ship, secret rotation, exposure -> `security-and-supply-chain`;
- how the events-processor pipeline works (modes, commits, DLQ) -> `architecture-contract`;
- Rails vs Go semantics of event values/time -> `rails-go-parity`; billing glossary -> `domain-reference`;
- toolchain/CGO env (`CGO_LDFLAGS`, `LD_LIBRARY_PATH`) -> `build-and-env`;
- change gates and commit rules -> `change-control` (this skill cites them as "change-control N#", classes C0-C7).

## Terms

- **Plane**: one way configuration reaches a process (a compose file, an env file, a script default map, code defaults).
- **DEF**: `.env.development.default`, the single dev source of truth (change-control N12).
- **Anchor**: YAML `x-backend-environment: &backend-env` mapping merged into services with `<<:`; only listed keys reach containers.
- **Interpolation**: compose substitution of `${VAR}` / `${VAR:-default}` before containers start.
- **Empty-but-set**: variable present with value `""` (DEF `VAR=`, anchor `${VAR:-}`). Not the same as unset.
- **Read idiom**: how code turns the string into a decision (`.present?`, `== "true"`, `Boolean.cast`, `GetEnvAsBool`, ...).
- **Baked**: copied into persistent state at creation time (ClickHouse Kafka-engine DDL), so later env changes have no effect.
- **`$API`** / **`$FRONT`**: pinned checkouts from `.claude/skills/research-methodology/scripts/pinned-checkout.sh api|front`.

```bash
cd "$(git rev-parse --show-toplevel)"
API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)
```

## 1. The planes: what reads what

| # | Plane | Files | How env reaches the process | Interpolation |
|---|---|---|---|---|
| 1 | Dev stack | `docker-compose.dev.yml`, DEF, optional `.env.development` (git-ignored, `.gitignore:4`) | `env_file:` on redis (`docker-compose.dev.yml:71-74`), migrate (`:150-153`), api (`:180-183`), api-worker and everything merged from it with `<<: *api_worker` (7 dedicated workers, events-consumer; `:213-216`), api-clock (`:308-311`), events-processor (`:333-336`), pghero, redis-replica/sentinels (`:500-503,525-528,556-559`); **front has no env_file**, only `environment:` (`:104-111`) | yes, inside env files too (section 2) |
| 2 | Root self-host | `docker-compose.yml:20-73` anchor `x-backend-environment`, `x-frontend-environment` (`:74-78`), `x-lago-api-url`/`x-lago-front-url` (`:15-18`); project `.env` | only anchor keys; `.env` feeds `${}` only | yes |
| 3 | Deploy variants | `deploy/docker-compose.{local,light,production}.yml`, `deploy/.env.{light,production}.example`, `deploy/deploy.sh` | same anchor pattern; images frozen at `getlago/api:v1.27.1` (`deploy/docker-compose.production.yml:15`) | yes |
| 4 | Single image | `docker/runner.sh` default map (`:5-21`), `/data/.env` | `/data/.env` exported first (`:23-25`), defaults fill EMPTY vars and are persisted (`:64-74`) | shell |
| 5 | Agentic demo | `examples/agentic-ai-demo/compose.yml` (+ `run.sh:57` derives `LAGO_VERSION` from root api tag) | plain `environment:` on the single image | yes |
| 6 | Connectors | `connectors/{http,sqs,kinesis}.yml` | Redpanda Connect `${VAR}` / `${VAR:default}` (`connectors/http.yml:41,45`) | own syntax |
| 7 | events-processor | `os.Getenv` + `events-processor/utils/env.go:9-52` | real process env only; **no dotenv** (`grep -rn dotenv events-processor` is empty) | none |
| 8 | lago-api | `ENV[...]` at `$API`; dev/test also `Dotenv.load` of `api/.env` (`$API/config/environments/development.rb:76`, `test.rb:47`), which fills only UNSET vars | | ERB in YAML |
| 9 | lago-front | `$FRONT/.env.sh:6-14` at container start (dev: vite `define`) | | |

Key facts (VERIFIED):
- ROOT and deploy ship **no** events-processor, Redpanda or ClickHouse: every event-pipeline variable exists only in the dev plane here. Production values live outside this repo (UNVERIFIED).
- The repo-root project `.env` is read by BOTH `docker-compose.yml` and `docker-compose.dev.yml` (same directory): a self-host `.env` there changes dev interpolation too (scratch copy with `.env` = `POSTGRES_PASSWORD=projpw`: `docker compose -f <file> config` puts `projpw` into the api `DATABASE_URL` for both files).
- Full per-plane tables: `reference/platform-env.md` (wrapper/lago-api variables), `reference/events-processor-env.md` (all 29 Go reads).

## 2. Precedence and interpolation (dev plane) — verified with `docker compose config`

Ran in a scratch copy (`cp docker-compose.dev.yml .env.development.default $TMPDIR/x/`), `env -i`, Compose v5.3.1, no daemon:

<!-- evidence-check: off evidence = the reproduce block at the end of this section (scratch-copy docker compose config) -->

| Experiment | Result |
|---|---|
| baseline | EP gets `DATABASE_URL=postgresql://lago:changeme@db:5432/lago` (DEF:24 `${POSTGRES_USER}` etc. resolved), `LAGO_KAFKA_TLS=""` |
| shell `POSTGRES_PASSWORD=shellpw` | `DATABASE_URL` uses `shellpw`; the container's own `POSTGRES_PASSWORD` stays `changeme` |
| `.env.development` with `POSTGRES_PASSWORD=devpw`, `LAGO_REDIS_STORE_DB=7` | container gets `devpw` and `7`, but `DATABASE_URL` keeps `changeme` |
| `.env.development` with `DATABASE_URL=postgresql://${POSTGRES_USER}:x@db/override` | EP gets the override (`lago` resolved from DEF); `migrate` keeps its `environment:` value |
| project `.env` with `POSTGRES_PASSWORD=projpw` | `DATABASE_URL` uses `projpw`; db container too |
| shell `ENV=production` (not in DEF) | does NOT reach any container |

Rules that follow:
1. Container value: service `environment:` > `.env.development` > DEF.
2. `${VAR}` inside an env file IS interpolated (`docs/dev_environment.md:158` says the opposite: stale). Lookup: shell, then project `.env`, then keys defined earlier in the same or an earlier env file. A later file never re-interpolates an earlier one.
3. Shell and project `.env` never override an env_file KEY; they only feed `${}`.
4. To change the dev DB password, set it in the shell or project `.env` (feeds `db` service and DEF:24), not in `.env.development`. Caveat: the app containers' own `POSTGRES_PASSWORD` key stays `changeme` (rule 3), and lago-api's `development:` database config hard-codes `password: changeme` (`$API/config/database.yml:20-45`); whether lago-api dev then connects is UNVERIFIED, so keep `changeme` in dev unless you have tested it.
5. Empty values are passed as `""` (set), never dropped.

<!-- evidence-check: on -->

Root/deploy: a key not listed in the anchor never reaches the container, whatever `.env` says. To pass one, edit the anchor (change class C6).

Reproduce one row (read-only):
```bash
d=$(mktemp -d); cp docker-compose.dev.yml .env.development.default "$d"/
printf 'POSTGRES_PASSWORD=devpw\n' > "$d/.env.development"
(cd "$d" && env -i PATH="$PATH" HOME="$HOME" docker compose -f docker-compose.dev.yml config --format json \
  | jq -r '.services["events-processor"].environment | "\(.DATABASE_URL) \(.POSTGRES_PASSWORD)"')
# expect: postgresql://lago:changeme@db:5432/lago devpw
```

## 3. Defaults that differ by plane (most consequential; full table in reference/platform-env.md)

| Variable | DEV | ROOT | deploy (LOC/LIT/PRD) | RUN | Consequence |
|---|---|---|---|---|---|
| `LAGO_DISABLE_SEGMENT` | `true` | `""` | `""` | – | telemetry ON for self-hosters (`== "true"`, `$API/config/initializers/analytics_ruby.rb:3`) |
| `LAGO_DISABLE_WALLET_REFRESH` | `true` | `""` | `""` | – | wallet refresh ON wherever `LAGO_REDIS_CACHE_URL` is set (always in ROOT/deploy; `$API/clock.rb:55-56`) |
| `LAGO_CLICKHOUSE_ENABLED` | `true` | – | – | – | CH paths only in dev here (`.env.development.default:7`) |
| `LAGO_DISABLE_PDF_GENERATION` | `false` | `false` (api+front) | **absent** | – | cannot disable PDFs in deploy without editing (root has it at `docker-compose.yml:55,78`) |
| `LAGO_REDIS_CABLE_URL` | – | `""` | `""` | – | `ENV.fetch` keeps `""`: REDIS_URL fallback skipped (`$API/config/cable.yml:3`, section 5) |
| `LAGO_API_URL` | `https://api.lago.dev` | `http://localhost:3000` | LOC same; LIT/PRD `https://${LAGO_DOMAIN}/api` | `http://localhost:3000` | unset `LAGO_DOMAIN` renders `https:///api` (compose only warns; `deploy/docker-compose.light.yml:24`) |
| `MISTRAL_*`, `LAGO_DATA_API_*` | set | set | **absent** | – | root-only additions (`3941b69`, `5f5d957`) |
| `LAGO_SIDEKIQ_WEB` | `true` | `true` | `true` | – | unauthenticated `/sidekiq` (route to `security-and-supply-chain`) |
| encryption placeholders | `your-encrpytion-*` (typo) | `your-encryption-*` | same | random | dev and prod placeholders differ (`.env.development.default:72-74` vs `docker-compose.yml:29-31`) |

`env-crossref.sh` prints the name-level drift (GAP4a today: `LAGO_DATA_API_BEARER_TOKEN LAGO_DATA_API_URL LAGO_DISABLE_PDF_GENERATION MISTRAL_AGENT_ID MISTRAL_API_KEY` are in root but not in every deploy file).

## 4. Feature flags and toggles: classification

Classes: **PROD** = supported self-host/production knob · **PIPE** = needed wherever the event pipeline runs (wired only in dev here) · **DEV** = dev-only · **EXP** = experimental · **DEPR** = deprecated · **DEAD** = read by nobody / points at nothing.

| Flag | Defaults | Class | Evidence and notes |
|---|---|---|---|
| `LAGO_USE_MEMORY_CACHE` | unset in every plane of this repo (dev = DB mode); production sets `true` in a deploy config outside this repo | **PROD (`true`)**: DECIDED OD-1 (owner, 2026-10-02), production runs memory-cache mode | EP `main.go:67` exact `== "true"` (`1`/`TRUE` silently = DB mode); CDC consumers ignore SASL/TLS and do not split broker lists (`cache/consumer.go:28-35`); the production CDC config (Debezium column list, Kafka auth, brokers) is OPEN DECISION OD-1b (owner). Hardening: `event-accounting-campaign` W6 (DEFAULT APPLIED OD-20; as-is defects `architecture-contract` WP6-WP10) |
| `LAGO_DEBEZIUM_TOPIC_PREFIX` | unset (dev) | PROD (required whenever `LAGO_USE_MEMORY_CACHE=true`, not enforced) | must equal Debezium `topic.prefix` (`extra/debezium_config.json:47` = `lago_proc_cdc`, a file no script applies; README example `lago_dbz`); `""` gives `.public.<table>` silently; the production value is OPEN DECISION OD-1b (owner) |
| `KAFKA_TRACING_ENABLED` | unset (off) | optional OBS | no-op unless a tracer provider is active (`config/kafka/kafka.go:40-46`, empty provider has no hooks); never applies to CDC consumers; prod use UNVERIFIED |
| `TRACING_PROVIDER`, `DD_*`, `OTEL_*` | unset | optional OBS | `config/tracing/tracer.go:47-139`; none in DEF; README documents only the three `OTEL_*` (`events-processor/README.md:64-66`) |
| `LAGO_CLICKHOUSE_ENABLED` | DEV `true` | PIPE | **MIXED** (`bool-semantics.sh`; this skill owns the ruling): with `=false` the 12 `.present?`/`.blank?` sites stay ON (e.g. `$API/app/services/events/stores/store_factory.rb:10`); org creation (`Boolean.cast`, `$API/app/services/organizations/create_service.rb:17`) and 2 seed `== "true"` sites turn OFF. `docs/dev_environment.md:154` is wrong |
| `LAGO_CLICKHOUSE_MIGRATIONS_ENABLED` | DEV `true` | PIPE | MIXED: `.present?` `$API/config/database.yml:56` vs `== "true"` `$API/scripts/start.sh:10` |
| `SIDEKIQ_EVENTS/PDFS/BILLING/CLOCK/WEBHOOK/ANALYTICS/AI_AGENT` | DEV `false` (`.env.development.default:46-52`); ROOT commented hints `docker-compose.yml:67-73` (all but ANALYTICS, plus ALERTS); deploy none | PROD | enqueue-time `Boolean.cast` (`$API/app/jobs/bill_subscription_job.rb:5`): set it on every enqueuing process and run the matching worker; uncommenting the root hints breaks YAML (section 9). Detail: reference/platform-env.md section F |
| `SIDEKIQ_ALERTS` (alerting worker) | not in DEF; ROOT commented `api-alerts-worker` (`docker-compose.yml:232-244`, `f2e202a`) | PROD option | queues `alerts_high_priority`/`alerts` (`$API/config/sidekiq/sidekiq_alerts.yml`); no dev service; `SIDEKIQ_PAYMENTS`, `SIDEKIQ_WALLETS` likewise have no wrapper wiring |
| deploy/production dedicated workers | services exist, flags never set | PROD (broken) | jobs never routed to them; `pdf-worker` runs `./scripts/start.pdf.worker.sh` (`deploy/docker-compose.production.yml:346`), absent at `$API/scripts` and in lago-api `v1.27.1` (the image deploy runs; only `start.pdfs.worker.sh`) |
| `LAGO_WALLET_ONGOING_BALANCE_REFRESH_INTERVAL_SECONDS` | passed nowhere; documented `docs/architecture.md:332` (`8efaf8a`) | PROD tuning (api-only) | integer seconds (`.to_i.seconds`, `$API/clock.rb:57-59`); runs only with a cache configured and `LAGO_DISABLE_WALLET_REFRESH != "true"` (`$API/clock.rb:55-56`); ROOT needs an anchor edit |
| `LAGO_DISABLE_WALLET_REFRESH`, `LAGO_DISABLE_SEGMENT`, `LAGO_DISABLE_SIGNUP` | see section 3 | PROD | `== "true"` (exact): `$API/clock.rb:56`, `$API/config/initializers/analytics_ruby.rb:3`, `$API/app/services/users_service.rb:45` |
| `LAGO_DISABLE_PDF_GENERATION`, `LAGO_DISABLE_SSL`, `LAGO_DISABLE_EVENTS_VALIDATION` | see platform-env | PROD | `Boolean.cast` (`"no"`/`"False"` count as TRUE): `$API/app/services/invoices/generate_pdf_service.rb:100`, `$API/config/environments/production.rb:34`, `$API/clock.rb:175` |
| `LAGO_USE_AWS_S3`, `LAGO_USE_GCS` | `false` | PROD | S3 MIXED: `$API/config/environments/staging.rb:18` uses `.present?` only |
| `LAGO_SIDEKIQ_WEB` | `true` everywhere | PROD (insecure default) | `== "true"` `$API/config/routes.rb:4`; the self-host default is OPEN DECISION OD-16 (owner, security) |
| `LAGO_CREATE_ORG` (+ `LAGO_ORG_*`) | DEV `true`, ROOT `false` | PROD bootstrap | `$API/lib/tasks/signup.rake:6` |
| `LAGO_KARAFKA_WEB`, `LAGO_KARAFKA_PROCESSING` | DEV `""` | DEV | MIXED: `""` mounts `/karafka` (`$API/config/routes.rb:8`, truthy) while `Karafka::Web.enable!` needs `.present?` (`$API/karafka.rb:70`) and `$API/scripts/karafka.web.sh:3` needs `== "true"` |
| `LAGO_REDIS_SIDEKIQ_SENTINELS` | DEV `""` | PROD option | `.presence` `$API/lib/lago/redis_config_builder.rb:63`; dev profile `redis-sentinel` (`docker-compose.dev.yml:536`) |
| `LAGO_DEFAULT_EVENT_STORE` | api-only | PROD (cloud) | `== "clickhouse"` with `Boolean.cast(LAGO_CLICKHOUSE_ENABLED)` makes new orgs ClickHouse-store AND sets `clickhouse_deduplication_enabled` (`$API/app/services/organizations/create_service.rb:17-20`); the only env-driven setter (others: rake recipe `$API/lib/tasks/recipes/clickhouse.rake:109`, enriched-store migration `comparison_service.rb:61-64`) |
| `ENV=production` as Redis TLS switch | — | DEPR | `events-processor/processors/main_processor.go:84-85` ("Deprecated: Use env LAGO_REDIS_STORE_TLS") |
| EP `LAGO_REDIS_CACHE_*` | — | DEAD | constants only, `events-processor/processors/main_processor.go:40-43` (last reader removed in `2fd8e8b`) |
| `LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC` | removed from DEF (`d9c32b6`) | DEAD (still read) | `$API/db/clickhouse_migrate/20250814124830_create_events_enriched_expanded_queue.rb:9` (section 7) |
| `LAGO_DATA_API_URL` target; dev-front `NANGO_SECRET_KEY`; `x-lago-domain` anchor | — | DEAD | no `data-api`/`data_api` service in any compose file here; the front reads `NANGO_PUBLIC_KEY`; anchor never merged (`deploy/docker-compose.light.yml:18-19`) |
| `LAGO_MCP_SERVER_URL` | DEV `http://mcp-server:3001/mcp` (`.env.development.default:3`) | EXP | read at `$API/app/services/ai_conversations/stream_service.rb:76`; the target is defined only by the getlago/lago-agent-toolkit overlay `mcp/docker-compose.dev.yml` (second `-f` + `LAGO_MCP_SERVER_PATH`); undocumented here (`docs-and-writing` SC-34) |

Not env vars: `pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation` are per-organization
flags in the lago-api database (`organization.feature_flag_enabled?`, e.g. `$API/app/services/events/stores/store_factory.rb:41`);
their production state is OPEN DECISION OD-8 (owner). See `rails-go-parity`.

Owner decisions touching this registry (register OD-1..OD-20 in `change-control`): DECIDED OD-1 (owner, 2026-10-02):
production runs memory-cache mode; DECIDED OD-4 (owner, 2026-10-02): a cross-repo change needs a paired PR in each
repo that reads or writes the changed part (no blanket rule). Still the owner's call, never present as settled:
OPEN DECISION OD-1b (owner) (production CDC config), OD-8, OD-9, OD-16; OD-20 is DEFAULT APPLIED (campaign W6).
Route any change that touches them through the `change-control` gate.

## 5. Parsing traps

Ruby idioms (computed with exact emulations of ActiveSupport `blank?` and ActiveModel Boolean at Rails 8.0.5.1):

<!-- evidence-check: off evidence = bool-semantics.sh (same truth table per family) and the Rails 8.0.5.1 sources in Provenance -->

| value | `.present?` | `== "true"` | `Boolean.cast` | `if ENV[x]` / `ENV.key?` | Go `GetEnvAsBool(x,false)` |
|---|---|---|---|---|---|
| unset | off | off | off (nil) | off | false |
| `""` | off | off | off (nil) | **ON** | false |
| `" "` | off | off | **ON** | ON | false |
| `true` | ON | ON | ON | ON | true |
| `false` / `0` | **ON** | off | off | ON | false |
| `no` | ON | off | **ON** | ON | false (default) |
| `False` / `TRUE` | ON | off | ON / ON | ON | false / true |
| `1` | ON | off | ON | ON | true |

<!-- evidence-check: on -->

Traps (all VERIFIED unless marked):
1. **`=false` enables `.present?` readers.** Disable by unsetting or `VAR=` — never `false`. Run `bool-semantics.sh VAR` before trusting any value.
2. **Empty-but-set.** Compose passes `""` for DEF `VAR=` and anchor `${VAR:-}`. Ruby `ENV.fetch("X", d)` returns `""` (default only when the KEY is absent) and `ENV["A"] || x` returns `""`. Live case: `$API/config/cable.yml:3,11,16` `ENV.fetch("LAGO_REDIS_CABLE_URL", ENV.fetch("REDIS_URL", …))` gets `""` in ROOT/deploy, so ActionCable never falls back to `REDIS_URL` (runtime effect UNVERIFIED; CANDIDATE defect, cross-repo). `.presence` and Go `GetEnvOrDefault` treat `""` as unset.
3. **Go booleans fall back silently.** `GetEnvAsBool` (`events-processor/utils/env.go:35-43`) returns the default for anything `strconv.ParseBool` rejects (`yes`, `no`, `on`, `" true"`). `LAGO_REDIS_STORE_TLS=no` with `ENV=production` = TLS on.
4. **Go ints panic.** `GetEnvAsInt` (`events-processor/utils/env.go:9-20`) errors on `abc`, `" 5"`, `5.0`; callers panic (`LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` at `events-processor/processors/main_processor.go:134-137`, `LAGO_REDIS_STORE_DB`). `0` max connections -> pgxpool `MaxSize must be >= 1`.
5. **Ruby ints never fail.** `.to_i` keeps leading digits and drops the rest: `"5m".to_i == 5` (5 SECONDS, not 5 minutes), `"abc".to_i == 0` (verified with Ruby 3.3). Interval knobs (`$API/clock.rb:33,46,57`) take integer seconds. What clockwork does with a 0-second interval is UNVERIFIED.
6. **`rediss://` does not mean TLS in Go.** EP strips `^rediss?://` (`config/redis/redis.go:25-28`) and uses TLS only if `LAGO_REDIS_STORE_TLS` (or `ENV=production`). Credentials or `/db` in the URL break EP: `redis://:pw@redis:6379/2` becomes address `:pw@redis:6379/2` (probe). Put password and DB in `_PASSWORD`/`_DB`. lago-api prepends `redis://` when no scheme (`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:48-52`). Empty `LAGO_REDIS_STORE_URL` in Go = `localhost:6379` (go-redis default).
7. **Comma broker lists.** EP main path splits and trims (`utils/env.go:22-33`); EP CDC consumers pass the raw string as ONE seed (`cache/consumer.go:28-31`): a client probe with `localhost:19092,localhost:29092` -> `lookup localhost:19092,localhost:29092: no such host`, while the running CDC loop logs nothing (`debugging-playbook` T5). Production runs cache mode (DECIDED OD-1): give it a single seed broker address (franz-go discovers the rest of the cluster from one seed) until W6 fixes the split; whether production passes a list is OPEN DECISION OD-1b (owner). `" "` passes the EP empty check (`[""]`).
8. **Startup crash on SCRAM typo.** `LAGO_KAFKA_SCRAM_ALGORITHM` other than `SCRAM-SHA-256`/`SCRAM-SHA-512` -> SIGSEGV in `kgo.validateCfg` (binary probe; `config/kafka/kafka.go:56-63`).
9. **Unvalidated EP strings.** `LAGO_KAFKA_RAW_EVENTS_TOPIC`/`LAGO_KAFKA_CONSUMER_GROUP` empty are accepted (`events-processor/processors/main_processor.go:168-172`); `LAGO_DEBEZIUM_TOPIC_PREFIX` empty is accepted (`events-processor/main.go:70`). Startup is only partially fail-fast (`architecture-contract` I14).
10. **Single image** parses `/data/.env` with `for LINE in $(cat …)`: values with spaces break (`docker/runner.sh:24`).

Stale config docs (verified 2026-10-01; the register with corrected text belongs to `docs-and-writing`):
- `docs/dev_environment.md:154`: `LAGO_CLICKHOUSE_ENABLED=false` does not disable ClickHouse. The 12 `.present?`/`.blank?` readers stay ON; only the `Boolean.cast` site (`$API/app/services/organizations/create_service.rb:17`) and the two `== "true"` seed files turn off (trap 1). `:158`: env files ARE interpolated (section 2).
- `docs/architecture.md:333`: Refresh Flagged Subscriptions runs every 10 seconds and needs `LAGO_CLICKHOUSE_ENABLED` present as well as `LAGO_REDIS_STORE_URL` (`$API/clock.rb:210-211`).
- `events-processor/README.md:47,57-59`: `LAGO_REDIS_CACHE_*` are dead in EP (`:47` lists one as required). `:56`: the `LAGO_REDIS_STORE_TLS` default is `ENV == "production"`, not `false`. `:68`: the variable is `LAGO_USE_MEMORY_CACHE`, not `USE_MEMORY_CACHE`.

## 6. Divergent vocabularies for the same thing

Kafka auth and TLS (one broker, several vocabularies):

| Consumer | SASL mechanism | TLS | Credentials | Source |
|---|---|---|---|---|
| events-processor main path | `LAGO_KAFKA_SCRAM_ALGORITHM` = `SCRAM-SHA-256`/`-512` | `LAGO_KAFKA_TLS` (ParseBool; verifies certs) | `LAGO_KAFKA_USERNAME`/`_PASSWORD` | `processors/main_processor.go:109-116` |
| events-processor CDC consumers | none | none | none | `cache/consumer.go:30-35` |
| lago-api (Karafka/WaterDrop, librdkafka) | `LAGO_KAFKA_SASL_MECHANISMS` | `LAGO_KAFKA_SECURITY_PROTOCOL` (e.g. `SASL_SSL`) | same `LAGO_KAFKA_USERNAME`/`_PASSWORD` | `$API/karafka.rb:9-27` |
| ClickHouse Kafka engine | not in DDL (server config; UNVERIFIED) | not in DDL | not in DDL | `$API/db/clickhouse_migrate/*_queue.rb:8-10` |
| connectors | hard-coded `SCRAM-SHA-512` | `KAFKA_TLS` (sqs.yml hard-codes `true`) | `KAFKA_USER`/`KAFKA_PASSWORD`, brokers `KAFKA_BROKERS` | `connectors/http.yml:41-49`, `sqs.yml:43-51` |

For a SASL_SSL SCRAM-512 cluster set BOTH vocabularies: `LAGO_KAFKA_SCRAM_ALGORITHM=SCRAM-SHA-512 LAGO_KAFKA_TLS=true` (EP) and `LAGO_KAFKA_SASL_MECHANISMS=SCRAM-SHA-512 LAGO_KAFKA_SECURITY_PROTOCOL=SASL_SSL` (lago-api; librdkafka value names, runtime UNVERIFIED here). The cache-mode CDC consumers cannot authenticate at all (`cache/consumer.go:30-35`): on a SASL/TLS cluster production's cache would never see an edit after its startup snapshot. Which auth production's CDC consumers face is OPEN DECISION OD-1b (owner).

Redis TLS for the shared flag store (`subscription_refreshed_v2`, a cross-repo contract, change-control N6):

| Side | TLS switch | Scheme `rediss://` | Cert verification |
|---|---|---|---|
| events-processor (writer) | `LAGO_REDIS_STORE_TLS` (ParseBool, default `ENV=="production"`) | stripped, ignored | always skipped (`InsecureSkipVerify`, `config/redis/redis.go:42-46`) |
| lago-api (reader) | `LAGO_REDIS_STORE_SSL` (`.present?`: `false` turns SSL ON) | enables SSL | on, unless `LAGO_REDIS_STORE_DISABLE_SSL_VERIFY` is present (`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:63-67`) |
| lago-api Sidekiq/cache | scheme of `REDIS_URL`/`LAGO_REDIS_CACHE_URL` | enables SSL | always `VERIFY_NONE` (`$API/lib/lago/redis_config_builder.rb:55-57,75-77`) |

Both sides must also agree on `LAGO_REDIS_STORE_DB` (dev: `1`; incident `3cd78f1` was a DB mismatch on the old cache). Unifying the names is CANDIDATE, not decided; it is a cross-repo change (C4/C7) and lago-api reads `LAGO_REDIS_STORE_SSL`, so it needs a paired lago-api PR (DECIDED OD-4: dependency-driven).

## 7. Topic names are baked into ClickHouse DDL

Seven lago-api ClickHouse migrations create Kafka-engine `*_queue` tables whose `kafka_broker_list`,
`kafka_topic_list` and `kafka_group_name` are string-interpolated from env AT MIGRATION TIME
(`$API/db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:8-10`, and the `_queue` files of
`20240705084952` enriched, `20250416104012` activity_logs, `20250605171311` api_logs, `20250814124830`
enriched_expanded, `20251110130723` dead_letter, `20260202135507` security_logs).

Consequences:
- Changing `LAGO_KAFKA_*_TOPIC`, `LAGO_KAFKA_BOOTSTRAP_SERVERS` or `LAGO_KAFKA_CLICKHOUSE_CONSUMER_GROUP` later changes the producers/consumers immediately but NOT existing ClickHouse tables (values interpolated once, `$API/db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:8-10`): ClickHouse keeps reading the old topic and the new one is silently not ingested.
- A fresh dev ClickHouse still runs `20250814124830` with `LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC` unset (removed from DEF in `d9c32b6`): queue table with an empty topic list (effect UNVERIFIED).
- Dev topic creation uses LITERAL names, not the env (`docker-compose.dev.yml:398-405`): renaming a topic in `.env.development` does not create it (Redpanda auto-create UNVERIFIED).
- Renaming `LAGO_KAFKA_CONSUMER_GROUP` or the raw topic creates a new EP group `<group>_<topic>` that starts at the earliest offset (replay; see `architecture-contract`).

To change a topic name: treat it as C4 (change-control N6; the ClickHouse `_queue` tables in lago-api depend on it, so a paired lago-api PR: DECIDED OD-4; a topic no other repo reads, such as ADR-001's internal retry topic, needs none): new ClickHouse migration that recreates the `_queue` table (lago-api), DEF + `redpandacreatetopics` list, EP/API env together, planned deploy order. Inspect what a live table baked (not runnable here): `SHOW CREATE TABLE events_enriched_queue`.

## 8. Add / rename / remove a variable — checklist

File sets measured from history (`H=$(.claude/skills/research-methodology/scripts/history-setup.sh); git -C "$H" show --name-only --format= <sha>`):

| Kind | Real file set | Evidence |
|---|---|---|
| lago-api knob for self-hosters | `docker-compose.yml` + `deploy/docker-compose.{local,light,production}.yml` | `36327d2` (all 4); `3941b69` DEF + root -> drift; `5f5d957` root only (2025-03-07, before `deploy/` existed; the deploy files, first added in `4f36fd8` 2025-03-19, never got these keys) -> drift |
| api + front variable | DEF + `docker-compose.dev.yml` (front `environment:`) + root back AND front anchors | `18f8ef8` (2025-03-18, a day before `deploy/` was added; deploy never got it -> still missing) |
| dev-only variable | DEF only | `7851f50`, `85a91cc`, `37fdd04`, `18e9378` |
| events-processor variable | Go const + read, DEF, sometimes `utils/env.go`; README rarely (step 10 makes it mandatory) | `f277b44`, `7421650`, `a918f60` (README yes, DEF no), `475761d`/`1f2d36e` (Go only). This Go-only pattern is why 14 EP reads (tracing, `ENV`, `SENTRY_DSN`, cache mode, `LAGO_REDIS_STORE_TLS`) are missing from DEF today (gap GAP1) |
| new Kafka topic | DEF + `redpandacreatetopics` (+ lago-api CH `_queue` migration) | `1c3799b`, `a9d431e`, `330b048`; `f6852c0` "Add missing topic in dev env" |
| dedicated Sidekiq worker | DEF (`SIDEKIQ_X`, `SIDEKIQ_CONCURRENCY_X`) + dev service with shim + root commented template + `docs/architecture.md` | `f161215`; `d065ee1` (shim); `f2e202a` (alerts: root + docs only) |
| removal | DEF + dev compose + component README + code | `d9c32b6`, `4230f1f`, `a41c6dc` |

Stats: 28 commits touched DEF (or its earlier name); 15 also touched dev compose, 3 root compose, 0 deploy, 6 events-processor, 5 docs/README. The deploy compose files changed in only 4 commits ever.

Checklist (do every step or write in the PR why not):
1. **Name**: `LAGO_` prefix; `LAGO_DISABLE_<X>` / `LAGO_USE_<BACKEND>` / `LAGO_<X>_ENABLED`; `LAGO_<JOB>_INTERVAL_SECONDS` (integer seconds); topics `LAGO_KAFKA_<NAME>_TOPIC` with snake_case values. Grep first: `.claude/skills/config-and-flags/scripts/env-crossref.sh --matrix-only --filter '<NAME>'` must end with `rows: 0` (no collisions; also try a looser regex for near-duplicates like `_CONNEXIONS`).
2. **One idiom** (CANDIDATE convention, not a repo rule): Go `utils.GetEnvAsBool(name, default)` with documented default; Ruby `ActiveModel::Type::Boolean.new.cast(ENV["X"])` (what all `SIDEKIQ_*` use). Never `.present?` for a boolean. Afterwards `bool-semantics.sh X` must say UNIFORM.
   **Numeric/duration knob**: unit suffix in the name (`_MS`, `_SECONDS`). Go: `utils.GetEnvAsInt` (`events-processor/utils/env.go:9-20`: `""` = default, `"0"` = a real 0, junk = error). Validate the range in our code and fail with a specific `utils.LogAndPanic` message before any network step; a value the library rejects only at client creation surfaces as a misleading `failed to initialize ... producer` panic (`events-processor/processors/main_processor.go:55-76,118-131`). EP DEF entry: empty unless dev needs a non-default (no second copy of the default). lago-api: never ship `X=` for a number (`ENV.fetch` keeps `""`, `"".to_i == 0`; traps 2 and 5).
3. **Code + test** in the consumer (EP: const in `main.go`/`processors/main_processor.go`; helper change -> `utils/env_test.go`). EP change = C2/C3 (an optional knob in `config/kafka/*.go` or `processors/main_processor.go` whose default preserves behaviour is C3 + C6: "C4 by path, C3 by behaviour", change-control `reference/change-classes.md`); gates change-control N9.
   **Knob that tunes a library**: read the library default first, make the Go default equal it, and pin it in a test. EP producers pass no options today (`events-processor/config/kafka/producer.go:34`), so they run franz-go defaults: v1.20.5 producer linger is 10 ms, max 1 minute (`pkg/kgo/config.go:565,322` in the module cache; probe `kgo.NewClient(...)` then `cl.OptValue(kgo.ProducerLinger)` printed `10ms`, VERIFIED 2026-10-01). A naive `GetEnvAsInt(key, 0)` would silently turn lingering OFF everywhere.
4. **DEF** entry with the dev value (change-control N12: one source of truth; never per-service duplicates). No real secret (change-control N11).
5. **Front?** add to dev `front.environment` (`docker-compose.dev.yml:104-111`), root `x-frontend-environment`, and lago-front `.env.sh` (separate repo).
6. **Root anchor** `x-backend-environment` (`docker-compose.yml:20-73`): `"VAR": ${VAR:-default}`. Choose the default knowing `${VAR:-}` = empty-but-set (section 5 trap 2). Missing `:-` produces "variable is not set" warnings.
7. **deploy/*.yml** (3 files, production uses unquoted keys) — or state why not. They run `getlago/api:v1.27.1` (`deploy/docker-compose.production.yml:15`): a variable that image does not read is inert there.
8. **Single image**: `docker/runner.sh` default map only if a non-empty default is needed.
9. **Topic**: DEF + `redpandacreatetopics` (`docker-compose.dev.yml:398-405`) + lago-api CH migration + section 7 (C4).
10. **Docs**: `events-processor/README.md` env table (EP), `docs/architecture.md` (worker/clock knobs), `docs/dev_environment.md` if dev-visible; lago-api asks every new env var to be documented with name, purpose, example (`$API/AGENTS.md:186`).
11. **Verify**: `for f in docker-compose.dev.yml docker-compose.yml deploy/docker-compose.{local,light,production}.yml; do docker compose -f $f config --quiet || echo FAIL $f; done` (daemon-less; today it prints only "variable is not set" warnings for `LAGO_DOMAIN`, `LAGO_AWS_S3_ENDPOINT`, `LAGO_DISABLE_SEGMENT`, `LAGO_DISABLE_WALLET_REFRESH`, `LAGO_REDIS_CACHE_PASSWORD`, `LAGO_RSA_PRIVATE_KEY`, and no FAIL); `env-crossref.sh --gaps-only` (no NEW gap); `bool-semantics.sh VAR` (booleans only: a plain value prints `Verdict: VALUE`, a name nobody reads exits 3); EP: `.claude/skills/build-and-env/scripts/ep-test.sh`, then the no-daemon end-to-end start `.claude/skills/diagnostics-and-tooling/scripts/smoke-binary.sh db --no-expected --env NEW_VAR=value` (a startup panic shows as `exit_before_sigterm=exit status 2`).
12. **Class**: DEF/compose/deploy only = C6; secret, auth, TLS or exposure = C7; topic/Redis-store/payload name = C4; docs only = C0. Evidence in the PR (change-control N13).
13. **Skills** (same PR): the row in `reference/events-processor-env.md` (EP) or `reference/platform-env.md`, the `29 R` count (section 1 and Provenance) and the `env-crossref.sh` counts in Scripts; if tests were added, refresh the validation-and-qa baseline (`.claude/skills/validation-and-qa/scripts/baseline.sh --write .claude/skills/validation-and-qa/scripts/baseline.json`). Prose counts go stale; the Provenance commands recompute them.

**EP-only variable** (read only by the events-processor): steps 1-4, 10 (`events-processor/README.md` env table), 11 (dev `docker compose config`, `env-crossref.sh`, `ep-test.sh`), 12, 13. Steps 5-9 are N/A because root, deploy and the single image run no events-processor (section 1); say so in the PR. A topic name is the exception (step 9, C4).

Rename: keep reading the old name as a fallback for at least one release and log a deprecation; `f277b44` -> `7421650` renamed `…_MAX_CONNEXIONS` with no alias. Remove: delete the reader, DEF key, compose entries, README rows AND constants (`2fd8e8b` left four dead consts), and check lago-api migrations still reading it (`d9c32b6`).

## 9. If you see X, do Y

| Symptom | Likely cause | Confirm | Fix |
|---|---|---|---|
| ClickHouse still used after `LAGO_CLICKHOUSE_ENABLED=false` | `.present?` readers | `bool-semantics.sh LAGO_CLICKHOUSE_ENABLED` | unset it or `LAGO_CLICKHOUSE_ENABLED=` |
| var set in `.env` has no effect in self-host | not in the anchor | `docker compose -f docker-compose.yml config --format json \| jq '.services.api.environment \| has("VAR")'` -> `false` (prints no value) | add to `x-backend-environment` (C6) |
| `.env.development` change ignored by `db` | `db` uses shell interpolation (`docker-compose.dev.yml:46`) | experiment table, section 2 | set it in shell/project `.env` |
| EP `panic: brokers not found` | `LAGO_KAFKA_BOOTSTRAP_SERVERS` empty | `printenv LAGO_KAFKA_BOOTSTRAP_SERVERS` (empty = cause). Never `env \| grep LAGO_KAFKA`: it prints `LAGO_KAFKA_PASSWORD` (change-control N11) | set it; startup order and panics: `architecture-contract` section 2, triage `debugging-playbook` section 2 |
| EP SIGSEGV in `kgo.validateCfg` | SCRAM value typo | value must be `SCRAM-SHA-256`/`-512` (`events-processor/config/kafka/kafka.go:56-63`) | fix value |
| EP cannot reach `rediss://` store | scheme ignored by EP | read `config/redis/redis.go:25-46` | `LAGO_REDIS_STORE_TLS=true` |
| lago-api store SSL on with `LAGO_REDIS_STORE_SSL=false` | `.present?` | `bool-semantics.sh LAGO_REDIS_STORE_SSL` | unset it |
| jobs never processed after `SIDEKIQ_X=true` | no worker for that queue | `docker compose -f docker-compose.dev.yml config --services \| grep worker` | start the worker (`run-and-operate`) |
| uncommented root `SIDEKIQ_*` hint breaks compose | list syntax inside a mapping | `docker compose -f docker-compose.yml config --quiet` | `"SIDEKIQ_EVENTS": "true"` |
| new topic not ingested by ClickHouse | DDL baked (`$API/db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:8-10`) | section 7 | new CH migration (lago-api, C4) |
| cache mode (production, DECIDED OD-1) gets no CDC updates with 2 brokers or on SASL/TLS | CDC consumers do not split and have no auth | section 5 trap 7, section 6 | single seed broker; auth: `event-accounting-campaign` W6; production config OPEN DECISION OD-1b (owner) |

## Scripts

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/env-crossref.sh` | name matrix across EP, DEF, the dev, root, deploy and demo compose files, runner.sh, lago-api (`--with-front` adds lago-front) + gap report GAP1-GAP6. Read-only; exit 0 report, 2 usage, 3 missing input | `.claude/skills/config-and-flags/scripts/env-crossref.sh --gaps-only` | `GAP1 …: 14`, `GAP2 …: 4` (`LAGO_REDIS_CACHE_*`), `GAP3 …: 0`, `GAP4a …: 5`, `GAP4b …: 0`, `GAP5 …: 48`, `GAP6 …: 0`; exit 0; ~0.4 s warm. Full matrix ends `rows: 255` (`rows: 264` with `--with-front`); `--tsv \| wc -l` = 256 (255 + header). `--no-api` skips GAP3/GAP5/GAP6 |
| `scripts/bool-semantics.sh VAR` | every read of VAR in `$API` and EP, idiom per site, truth table, verdict. Exit 0 uniform/value, 1 MIXED, 2 usage, 3 no reads (or lago-api checkout missing) | `.claude/skills/config-and-flags/scripts/bool-semantics.sh LAGO_CLICKHOUSE_ENABLED` | 15 sites (12 PRESENT, 2 EQ_TRUE, 1 BOOL_CAST) incl. `PRESENT $API/app/services/events/stores/store_factory.rb:10`; `Verdict: MIXED`; `Safe to turn OFF everywhere: <unset> ""`; exit 1; ~0.2 s |

MIXED today (exit 1): `LAGO_CLICKHOUSE_ENABLED`, `LAGO_CLICKHOUSE_MIGRATIONS_ENABLED`, `LAGO_USE_AWS_S3`, `LAGO_KARAFKA_WEB`, `LAGO_CLOUD`.
`env-crossref.sh` marks: EP `R`/`d`; DEF `x`/`r` (interpolated by another key); compose `S` set (any service), `i` interpolation-only, `h` container-shell shim, `a` dead anchor, `c` commented. Limitations: `S` does not say WHICH service (use `docker compose config`); the DEV column covers only keys written in `docker-compose.dev.yml` itself, so env_file keys show `.` there and appear in DEF; the API column counts literal `ENV[...]`/`ENV.fetch`/`ENV.key?`/`[ -v ]` reads only, so helper indirection (e.g. `$API/lib/lago/diagnostics.rb:160` `setting(label, "NAME")`) is not counted. `bool-semantics.sh` has the same blind spot.

## Provenance and maintenance

- Sources: `.env.development.default`, `docker-compose.yml:15-78`, `docker-compose.dev.yml`, `deploy/docker-compose.*.yml`, `deploy/.env.*.example`, `docker/runner.sh`, `examples/agentic-ai-demo/compose.yml`, `connectors/*.yml`, `events-processor/{main.go,processors/main_processor.go,config/**,cache/*.go,utils/env.go}`, `$API/{clock.rb,karafka.rb,config/**,app/**,db/clickhouse_migrate/**,scripts/*.sh}`, `$FRONT/.env.sh`; commits listed in section 8; Rails 8.0.5.1 `activemodel/lib/active_model/type/boolean.rb` and `activesupport/…/object/blank.rb` (fetched from GitHub for the truth table); redis-client 0.26.3 gem source from rubygems.org (`lib/redis_client/url_config.rb`, for the cable row); lago-api `v1.27.1` tree (`d=$(mktemp -d); git clone -q --depth 1 --branch v1.27.1 --filter=blob:none --no-checkout https://github.com/getlago/lago-api "$d"; git -C "$d" ls-tree --name-only HEAD scripts/`) for the deploy `pdf-worker` row.
- Volatile facts and one-line re-verification (as of 2026-10-01):
  - EP reads 29 vars + 4 dead: `.claude/skills/config-and-flags/scripts/env-crossref.sh --matrix-only --filter . | awk '$2=="R"||$2=="d"' | awk '{print $2}' | sort | uniq -c` -> `29 R`, `4 d`
  - matrix size: `.claude/skills/config-and-flags/scripts/env-crossref.sh --matrix-only | tail -1` -> `rows: 255`
  - deploy drift: `.claude/skills/config-and-flags/scripts/env-crossref.sh --gaps-only | grep -A1 '^GAP4a'` -> `: 5` and the five names in section 3
  - Ruby `.to_i`: `ruby -e 'p "5m".to_i, "abc".to_i'` -> `5`, `0`
  - `.present?` at store_factory: `grep -n 'LAGO_CLICKHOUSE_ENABLED' "$API/app/services/events/stores/store_factory.rb"` -> `10:` … `.present?`
  - env_file interpolation (prints a count, never the URL): `env -i PATH="$PATH" HOME="$HOME" docker compose --env-file /dev/null -f docker-compose.dev.yml config --format json | jq -r '.services["events-processor"].environment.DATABASE_URL' | grep -c '^postgresql://lago:changeme@db:5432/lago$'` -> `1`
  - deploy image pin: `grep -n 'getlago/api:' deploy/docker-compose.production.yml` -> `v1.27.1`
  - root api tag: `grep -n 'getlago/api:' docker-compose.yml` -> `v1.53.0`
  - baked topics: `grep -ln 'kafka_topic_list' "$API"/db/clickhouse_migrate/*.rb | wc -l` -> `7`
  - SCRAM crash: `sed -n 56,63p events-processor/config/kafka/kafka.go` -> switch with no default case
  - cable fallback: `grep -n LAGO_REDIS_CABLE_URL "$API/config/cable.yml"` -> 3 `ENV.fetch` lines
  - franz-go producer linger default (section 8 step 3): `grep -n 'linger:  ' "$(go env GOMODCACHE)/github.com/twmb/franz-go@v1.20.5/pkg/kgo/config.go"` -> `565:` … `10 * time.Millisecond`
- Update triggers: any change to DEF, any compose/deploy file, `docker/runner.sh`, `events-processor/**/*.go` adding `Getenv`; an `api`/`front` gitlink bump (re-run both scripts against the new `$API`); a deploy image bump; a franz-go bump in `events-processor/go.mod`; owner answers to OD-1b, OD-8, OD-9, OD-16, a reassignment of OD-20 (W6), or an amendment of DECIDED OD-1/OD-4.
