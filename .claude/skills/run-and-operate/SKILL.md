---
name: run-and-operate
description: Runbooks and output map for running the Lago umbrella repo - picking a variant (dev docker-compose.dev.yml + profiles, root docker-compose.yml, stale deploy/ + deploy.sh, all-in-one getlago/lago, events-processor binary, connectors, agentic-ai demo), bring-up and known breakages, where output lands (topics, consumer groups, Redis keys, Postgres/ClickHouse tables, DLQ, logs, Sentry, volumes, ports, *.lago.dev), events-processor ops (startup panics, SIGTERM drain, group reset = replay, DLQ, scaling, memory-cache), pg_partman maintenance, monitoring reality. Use on "docker compose up", "unknown flag --profile", "start.pdf.worker.sh", "deploy.sh", "lago_front_pnpm_store", "LAGO_RSA_PRIVATE_KEY", "Private key is blank", "brokers not found", "events_dead_letter", "replay", "pg_partman", "enriched_events_default", "/metrics". Not for variable meaning (use config-and-flags), image builds or releases (use release-and-images), hardening (use security-and-supply-chain) or pipeline internals (use architecture-contract).
---
# Run and operate Lago

How to start each runtime variant of this repo, what each one runs, where its output lands, and how to
operate the Go events-processor, Postgres partitioning and monitoring. Commands assume the repo root
(`cd "$(git rev-parse --show-toplevel)"`). Facts verified 2026-10-01 against HEAD 5308258 (the working
tree HEAD `08065ef` only adds `.claude/skills/`) unless marked. `docker compose up/exec/logs` cannot run
in a daemon-less sandbox: those lines are verified by reading the cited files; `docker compose config`
works without a daemon and was run.

## When to use / when NOT to use

Use this skill to:
- choose a variant, bring it up, tear it down, or upgrade it;
- find where a topic, key, table, log line, volume or hostname comes from;
- restart, scale, drain, reset or replay the events-processor, or inspect its DLQ;
- check or repair `enriched_events` partition maintenance; find out what can be monitored.

Do NOT use it for:
- what a variable means, defaults, boolean traps, adding a variable → `config-and-flags`;
- building or publishing images, release train, Docker Hub tags → `release-and-images`;
- secrets policy, exposure audit, TLS, PII → `security-and-supply-chain`;
- commit/delivery algorithm, invariants, memory-cache internals → `architecture-contract`;
- symptom → cause tables, DLQ error-code triage, log triage script → `debugging-playbook`;
- probes (kfake, binary smoke, scratch Postgres, clickhouse local) → `diagnostics-and-tooling`;
- local toolchain, CGO recipe, submodule HTTPS rewrite, `lago` alias setup → `build-and-env`;
- whether a change to compose/deploy files may merge (class C6) → `change-control`;
- why a file looks the way it does (history) → `failure-archaeology`.

## Terms

- **Variant**: one way to run Lago from this repo (a compose file, an image, or the bare binary).
- **Profile**: compose `profiles:` gate. `--profile X` is a GLOBAL flag: it goes before `up`.
- **Project name**: compose project; it prefixes volume names (`lago_dev_…`, `lago-production_…`; the
  root file has no `name:`, so its prefix is the checkout directory name).
- **Raw topic**: `events-raw` (`LAGO_KAFKA_RAW_EVENTS_TOPIC`), input of the events-processor.
- **Group id**: the events-processor consumer group, `<LAGO_KAFKA_CONSUMER_GROUP>_<raw topic>`.
- **DLQ**: dead-letter topic `events_dead_letter` and its ClickHouse copy table of the same name.
- **DB mode / memory-cache mode**: events-processor lookups via Postgres per event (default) or via an
  in-memory badger cache fed by Debezium CDC (`LAGO_USE_MEMORY_CACHE=true`).
- **bgw**: `pg_partman_bgw`, pg_partman's background worker that runs partition maintenance.
- **premake**: number of future monthly partitions created ahead (3 here).
- **`$API`**: read-only lago-api checkout at the pinned gitlink (591ae90):
  `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`. `$API/<path>:line` cites it.

## 1. Pick a variant

| Variant | Entry | Runs (images as of 2026-10-01) | Use when | Status |
|---|---|---|---|---|
| Dev stack | `docker-compose.dev.yml` (project `lago_dev`) | 25 services: traefik:v3, postgres-partman:15.0, redis:7, front/api/migrate/clock/8 workers/Karafka consumer built from `./api` `./front`, events-processor built from `./events-processor` (air), redpanda v25.2.10 + topic creator + console + Kafka Connect, clickhouse 26.2, gotenberg 8, webhook tester, pghero; profiles `mailpit`, `redis-sentinel` (+4) | developing api/front/events-processor; the ONLY variant with Kafka, ClickHouse and the events-processor | maintained |
| Root self-host | `docker-compose.yml` | 8 services: db (postgres-partman:15.0), redis, migrate, api, api-worker, api-clock (getlago/api:v1.53.0), front (getlago/front:v1.53.0), pdf (gotenberg 7.8.2). No Kafka/ClickHouse/events-processor; events use the Postgres store | small self-host, smoke-testing a release | maintained: bumped every release, CI `docker-ci.yml` brings it up on every push to main |
| deploy/ local, light, production | `deploy/docker-compose.{local,light,production}.yml`, `deploy/deploy.sh` | api/front **v1.27.1**, postgres:15 (no partman); light/production add Traefik v3.3 + Let's Encrypt; production adds 5 dedicated workers + Portainer; db/redis/rsa-keys only via profiles | only if you accept a release 26 minors old | STALE + broken (README syntax, missing pdf-worker script, idle workers, deploy.sh bugs) |
| All-in-one | `getlago/lago` image (`docker/`) | one container: nginx+front, api, Sidekiq, clock, local Postgres 17, Redis; optional PDF sidecar via docker.sock | demos, testing, staging (docker/README.md:5) | maintained (release-built) with data-persistence doubts (UNVERIFIED) |
| events-processor binary | `events-processor/` (`event_processors`) | the Go consumer only; needs Kafka, Postgres (DB mode), Redis | debugging the processor outside compose, smoke tests | first-party code; prod image `getlago/lago-events-processor` |
| Connectors | `connectors/*.yml` (Redpanda Connect 4.83.0) | HTTP / SQS / Kinesis → raw topic | high-volume ingestion into Kafka | no public image or run recipe; a numeric `precise_total_amount_cents` they forward makes the events-processor drop the record (no DLQ) |
| Agentic AI demo | `examples/agentic-ai-demo/run.sh` | all-in-one image at the root compose's api tag (v1.53.0), 127.0.0.1:8080/3001, seeded org | showing usage-based billing locally | maintained |

Full service/port/volume matrix, drift between variants and the deploy.sh defect ledger:
`reference/variants.md` (read when a variant misbehaves or you need an exact image/port/volume).

## 2. Preflight before any bring-up

| Run | Expect | If not |
|---|---|---|
| `.claude/skills/run-and-operate/scripts/compose-matrix.sh --brief` | `RESULT: all 6 compose file(s) valid`, exit 0 | a compose edit broke YAML; `docker compose -f <file> config` shows the line |
| `.claude/skills/run-and-operate/scripts/dev-preflight.sh` | `dev-preflight: 0 FAIL(s)` | follow each FAIL line (daemon, submodules, certs, hosts, external volume) |
| `.claude/skills/run-and-operate/scripts/selfhost-preflight.sh [--variant root|local|light|production] .env` | `selfhost-preflight: 0 FAIL(s)` | placeholder secrets, bad RSA key, deploy.sh-polluted `.env`, missing LAGO_DOMAIN |

## 3. Bring-up quick reference (full runbooks: `reference/runbooks.md`)

Never use the `lago` alias in scripts or agent shells (non-interactive shells do not load it; the
lago-cli binary of the same name has no `exec`). Use `docker compose -f docker-compose.dev.yml …`.

**Dev stack** (R1):
1. `git submodule update --init api front` (do not commit the gitlinks: change-control N1).
2. Certs: `mkcert -install; mkdir -p traefik/certs && (cd traefik/certs && mkcert -cert-file lago.dev.pem -key-file lago.dev-key.pem lago.dev "*.lago.dev")`.
3. `/etc/hosts`: `127.0.0.1` for `api app console mail pdf pghero traefik webhook` `.lago.dev`
   (`lago.dev` is a public domain: a missing entry can resolve to the internet).
4. `cp ./api/.env.dist ./api/.env && touch ./api/config/master.key`; `docker volume create lago_front_pnpm_store`.
5. `docker compose -f docker-compose.dev.yml up -d --wait db redis traefik clickhouse webhook`
6. `docker compose -f docker-compose.dev.yml up -d --wait front api api-worker api-clock`
7. Event pipeline: `docker compose -f docker-compose.dev.yml up -d events-processor api-events-consumer`.
Failure points: external volume missing; `LAGO_CLICKHOUSE_ENABLED=false` still enables ClickHouse;
changing `POSTGRES_USER/PASSWORD/DB` breaks hard-coded copies; `SIDEKIQ_X=true` without starting the
matching worker leaves jobs unprocessed.

**Root self-host** (R2): write `.env` with the RSA key AND real `SECRET_KEY_BASE`, `LAGO_ENCRYPTION_*`,
`POSTGRES_PASSWORD` (README.md:225 only shows the RSA key), run `selfhost-preflight.sh .env`, then
`docker compose up -d --wait`; check `curl -f http://localhost:3000/health`.
Failure points: write `LAGO_RSA_PRIVATE_KEY` as ONE line of base64 of a PEM (`openssl genrsa 2048 | openssl base64 -A`).
lago-api Base64-decodes it, aborts `Private key is blank` when empty, then parses it
(`$API/config/initializers/rsa_keys.rb:10,13-15,17`). A raw PEM, or base64 wrapped over UNQUOTED lines
(compose keeps only the first line), raises `OpenSSL::PKey::RSAError: Neither PUB key nor PRIV key`;
base64 wrapped inside double quotes works (compose joins the lines, `decode64` ignores newlines). These
cases and the empty key were checked on 2026-10-01 with ruby on the value `docker compose config` passes.
**PG 14 → 15 volume trap**: `97d1f0b` (first in v1.41.0) moved `db` from
`postgres:14-alpine` to `postgres-partman:15.0-alpine` on the same volume; Postgres will not start on
an older-major data dir. Dump/restore procedure: runbooks R2.

**deploy/** (R3): profile before `up`: `docker compose -f docker-compose.production.yml --profile all up -d`
(the README's `docker compose up --profile all` gives `unknown flag: --profile`; ran with `--dry-run`).
No profile = no db/redis/rsa-keys. production `pdf-worker` runs `./scripts/start.pdf.worker.sh`, absent
from lago-api (only `start.pdfs.worker.sh`); dedicated workers get no `SIDEKIQ_*=true` and idle.
Avoid `deploy.sh` (11 defects, `reference/variants.md` §4).

**All-in-one** (R4): `docker run -d --name lago -p 80:80 -p 3000:3000 -v lago_data:/data getlago/lago:v1.53.0`;
`docker exec lago cat /data/db.log` for migrations. Values persisted in `/data/.env` win over later `-e`.

**events-processor binary** (R5): `source .claude/skills/build-and-env/scripts/ep-env.sh`, build into
`$(mktemp -d)` (never `go build -o event_processors .` inside the repo: that name is not git-ignored),
export the env of §5.1, run. **Demo** (R6): `./examples/agentic-ai-demo/run.sh`, `--cleanup` to remove.

## 4. What output lands where (detail: `reference/output-map.md`)

| Component | Writes | Reads | Logs / errors |
|---|---|---|---|
| lago-api (Rails) | raw topic on every event when Kafka env is set (no key); `activity_logs`/`api_logs`/`security_logs` topics; Postgres `lago`; Redis (Sidekiq, cache, cable) | ZSET `subscription_refreshed_v2` (clock job, needs `LAGO_REDIS_STORE_URL` + `LAGO_CLICKHOUSE_ENABLED`); `events_charged_in_advance` (Karafka group `lago_events_charged_in_advance_consumer`, DLQ `unprocessed_events`) | stdout; Sentry if `SENTRY_DSN` |
| events-processor | `events_enriched`, `events_charged_in_advance` (key `<org>-<transaction_id>`), `events_dead_letter` (no key), ZADD `subscription_refreshed_v2` in `LAGO_REDIS_STORE_DB` (dev 1) | raw topic, group `lago_dev_events-raw` (dev); Postgres `billable_metrics`, `subscriptions`, `charges` (never writes PG); CDC topics `lago_proc_cdc.public.*` in cache mode | JSON slog on stdout (`service=post_process`); Sentry (full event attached) |
| ClickHouse (dev) | `events_raw`, `events_enriched` (ReplacingMergeTree), `events_dead_letter` (MergeTree), `activity_logs`, `api_logs`, `security_logs` | Kafka engine tables `<x>_queue`, group `clickhouse`; broker/topic baked into DDL at migration time | container stdout |
| Redpanda (dev) | 7 topics from `scripts/create-topics.sh` (+ `_connectors_*`) | | console https://console.lago.dev |
| Postgres `enriched_events` | written by lago-api only for orgs with flag `postgres_enriched_events` | | |

Volumes: root `<dir>_lago_{postgres,redis,storage}_data`; dev `lago_dev_*` + external
`lago_front_pnpm_store`; deploy `lago-<variant>_lago_{postgres,redis,storage,rsa}_data`; all-in-one `/data`.
Ports: dev 80/443/5432/6379/9000/9092/19092/8083; root 3000/80/5432/6379; light/production 443 + 8080
(Traefik dashboard, insecure); all-in-one 80/3000 (+3001 PDF sidecar); demo 127.0.0.1:8080/3001.

## 5. Operating the events-processor (detail: `reference/events-processor-ops.md`)

### 5.1 Required environment and startup panics (fail-fast; exit 2)
Required: `LAGO_KAFKA_BOOTSTRAP_SERVERS`, the three output topic vars, `LAGO_KAFKA_RAW_EVENTS_TOPIC`,
`LAGO_KAFKA_CONSUMER_GROUP` (not validated), `DATABASE_URL` (DB mode and cache snapshot),
`LAGO_REDIS_STORE_URL` (+ `_DB`, `_PASSWORD`, `_TLS`). Full registry: `config-and-flags`.
Ran on 2026-10-01 against a freshly built binary:

| Env given | Output |
|---|---|
| nothing | `{"level":"ERROR","msg":"brokers not found",…}` then `panic: brokers not found` |
| only `LAGO_KAFKA_BOOTSTRAP_SERVERS=127.0.0.1:1` | `panic: LAGO_KAFKA_ENRICHED_EVENTS_TOPIC variable is required` |
| + all three topics, broker down | `panic: unable to dial: dial tcp 127.0.0.1:1: connect: connection refused` (immediate) |
| + `LAGO_KAFKA_SCRAM_ALGORITHM=sha512` | `panic: runtime error: invalid memory address or nil pointer dereference` in `kgo.validateCfg` (only `SCRAM-SHA-256`/`SCRAM-SHA-512` work) |
| no `LD_LIBRARY_PATH` | `error while loading shared libraries: libexpression_go.so` (see build-and-env) |

`ENV=production` switches the Redis store to TLS unless `LAGO_REDIS_STORE_TLS=false`
(main_processor.go:84-91). There is no health endpoint: liveness = process alive.

### 5.2 Shutdown vs grace period
SIGTERM → stop polling → each partition consumer FINISHES its in-hand batch on a background context and
commits → leave group → exit 0 (log: `Received shutdown signal` … `Consumer group shutdown is complete`
… `Event processor stopped`; seen in the binary smoke on 2026-10-01). A poll returns up to 10,000 records
(config/kafka/consumer.go:168). Grace periods in play: compose stop default 10 s (no
`stop_grace_period` anywhere), dev `air` `kill_delay=10s`, Kubernetes default 30 s. SIGKILL before the
commit → the batch is redelivered → duplicates (enriched rows collapse at ClickHouse merge; DLQ rows do
not; pay-in-advance fees are guarded by unique indexes). Real drain time in production: UNVERIFIED;
measure from log timestamps.

### 5.3 Consumer-group reset = replay
A group without committed offsets starts at the EARLIEST offset (franz-go default; smoke log shows
`"At":-2`). So renaming `LAGO_KAFKA_CONSUMER_GROUP` or the raw topic replays the whole retained raw topic
through enrichment, in-advance, DLQ and refresh flags (consequence table in the reference). Group naming
is cross-repo contract K7 (change-control); the delivery contract is OPEN DECISION OD-2 (owner). Inspect
and seek with `rpk group describe|seek` inside the redpanda container (commands in the reference; not
run here).

### 5.4 DLQ and replay
Inspect: `docker compose -f docker-compose.dev.yml exec clickhouse clickhouse-client --password default --query "SELECT error_code, count() FROM events_dead_letter GROUP BY error_code"`
or `rpk topic consume events_dead_letter`. Unparseable records never reach the DLQ (Sentry + log only).
**No DLQ replay tool exists** in this repo or lago-api @591ae90. lago-api's `events:reprocess` rake task
re-feeds ClickHouse `events_raw` for flagged subscriptions: it is NOT a DLQ replay. A manual DLQ replay is
CANDIDATE only and needs an owner decision (OPEN DECISION OD-2, owner); design lives in `event-accounting-campaign`.

### 5.5 Scaling
Parallelism = raw-topic partitions per group; dev topics are created without `-p` (broker default, 1 on
a default Redpanda: UNVERIFIED). docs/architecture.md:262 sizes it at 1 replica, 2 cores / 2 Gi; the
public Helm chart hard-codes `replicas: 1`. DB mode opens up to `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS`
Postgres connections per replica (code default 200; the Helm chart sets 10 via `eventsProcessor.databasePool`).
A fetch error panics the process: rely on the restart policy.

### 5.6 Memory-cache mode (OPEN DECISION OD-1 (owner): production use UNKNOWN)
Needs `LAGO_USE_MEMORY_CACHE=true` (exact string), `LAGO_DEBEZIUM_TOPIC_PREFIX` matching the Debezium
connector (`extra/debezium_config.json`: `lago_proc_cdc`), `wal_level=logical`, and a manually
registered connector (no script/doc). Startup blocks on a full table snapshot; snapshot errors are not
fatal (empty cache → every event DLQ'd `fetch_billable_metric`). CDC consumers take a new
`lago_evp_<model>_<uuid>` group each start (full CDC replay, stale groups) and ignore SASL/TLS and comma
broker lists. Dev runs DB mode; treat these as code-level defects with UNVERIFIED production impact.

## 6. Partition maintenance (`enriched_events`; detail: `reference/partitioning.md`)

Right in `docs/database_partitioning.md`: monthly range partitions on `timestamp`, premake 3, retention 14
months, migrations skip without pg_partman, maintenance must run periodically. Wrong: (1) "no additional
setup with the default Docker Compose" — only the dev file preloads `pg_partman_bgw`
(`scripts/postgresql.conf:81-88`); the root image (`getlago/postgres-partman:15.0-alpine` = postgres 15.0
+ pg_partman v5.4.0, CMD `postgres`) has partman but no scheduler; deploy/ has no partman. (2) The
retroactive DDL has 15 columns; the schema has 18 → step 5 fails (`INSERT has more expressions than
target columns`, ran). (3) Step 4 re-creates index names still held by the renamed table → `relation
"idx_billing_on_enriched_events" already exists` (ran). Corrected SQL (CANDIDATE, ran on a throwaway DB)
is in the reference. Only orgs with flag `postgres_enriched_events` write this table.

Check any database: `psql "<url>" -X -q -f .claude/skills/run-and-operate/scripts/partman-check.sql`.

## 7. Monitoring reality (detail: `reference/monitoring.md`)

- lago-api: `/health`, `/ready`; Yabeda Prometheus `/metrics` always mounted (no auth);
  `/sidekiq` (Web UI, NO auth) and `/sidekiq/prometheus/metrics` when `LAGO_SIDEKIQ_WEB=true`, the
  default in every compose file; Sidekiq liveness TCP 8080 in workers; Sidekiq Pro StatsD optional.
- docs/monitoring.md describes a private `lago-sidekiqs` service at `:3000/prometheus/metrics`, omits
  `/metrics`, and has a stale queue table. README.md:190 oversells ("events, billing, dependencies").
- events-processor: no metrics, no health, no lag counter; traces only (OTel/Datadog), kotel Kafka meters
  only with OTel + `KAFKA_TRACING_ENABLED=true`. Lag comes from the broker (`rpk group describe`).
- In light/production, Traefik's `PathPrefix(/api/)` exposes `/api/metrics` and `/api/sidekiq` on the
  public domain (inferred from labels). Hardening: `security-and-supply-chain`.

## 8. If you see X → do Y

| You see | Cause | Do |
|---|---|---|
| `unknown flag: --profile` | profile after `up` (deploy/README.md) | `docker compose -f <file> --profile all up -d` |
| `lago: command not found` / `unknown command "exec" for "lago"` | alias not loaded / lago-cli binary | `docker compose -f docker-compose.dev.yml …` |
| front will not start, external volume error | `lago_front_pnpm_store` missing | `docker volume create lago_front_pnpm_store` |
| browser cert error or wrong site on `*.lago.dev` | no mkcert certs / no hosts entry | `dev-preflight.sh`, then R1 steps 3-4 |
| api/worker exit `Private key is blank` | no RSA key (root has no rsa-keys service) | add `LAGO_RSA_PRIVATE_KEY` (one-line base64) |
| `Neither PUB key nor PRIV key` at boot | raw PEM, or base64 wrapped over unquoted lines, in `.env` | `selfhost-preflight.sh .env`, regenerate with `openssl base64 -A` |
| dev: emails never arrive, delivery errors | pinned lago-api sends dev SMTP to `mailhog:1025` (`$API/config/environments/development.rb:70-73`); the service is `mailpit` since `8f8334e` (#777), no `mailhog` alias (inferred, not run) | runbooks R1 step 11 |
| db restarts: data files incompatible with server | PG 14 volume under PG 15 image (`97d1f0b`) | dump/restore, runbooks R2 |
| compose: `line N: unexpected character` in `.env` | deploy.sh wrote status lines into `.env` | delete non `KEY=VALUE` lines (`selfhost-preflight.sh` lists them) |
| production `pdf-worker` restart loop | `start.pdf.worker.sh` does not exist | point it at `./scripts/start.pdfs.worker.sh` (C6 change) |
| production dedicated workers idle | no `SIDEKIQ_*=true` routing | set the flags on all backend services or drop the workers (owner call) |
| `panic: brokers not found` / `… variable is required` | missing env | §5.1 table |
| SIGSEGV in `kgo.validateCfg` | bad `LAGO_KAFKA_SCRAM_ALGORITHM` | use `SCRAM-SHA-256` or `SCRAM-SHA-512` |
| events-processor restarts after `Fetch error` | non-context fetch error panics by design | fix broker connectivity; check restart policy |
| events "disappear" | unmarshal error (no DLQ), skipped retryable, DLQ produce failure | `debugging-playbook`, `architecture-contract` |
| `enriched_events_default` keeps growing | no partman scheduler (root/all-in-one) | `partman-check.sql`, reference/partitioning.md §4 |
| need EP metrics/health | none exist | broker lag + DLQ query + restart count (monitoring.md §3) |

## Scripts

| Script | Purpose | Example | Expected output (2026-10-01, this sandbox) |
|---|---|---|---|
| `scripts/compose-matrix.sh` | every tracked compose file: validity, unset-var warnings, project, profiles → services, per-service image/profiles/ports/volumes/Traefik rules, resolved volume names; `--check-scripts` checks `./scripts/*.sh` against pinned lago-api | `.claude/skills/run-and-operate/scripts/compose-matrix.sh --check-scripts` | 6 files valid; dev `services with no profile (25)`; root 25 unset-var warnings; `script MISSING pdf-worker -> ./scripts/start.pdf.worker.sh (not in lago-api@591ae90)`; exit 1 (0 with `--brief`) |
| `scripts/dev-preflight.sh` | dev bring-up blockers: daemon, compose parse, submodules, certs (expiry, SAN, key match), hosts vs Host() rules, api/.env, master.key, `.env.development` traps, external volume, busy ports, `lago` alias | `.claude/skills/run-and-operate/scripts/dev-preflight.sh` | 6 FAIL (no daemon, empty api/ front/, no certs, api/app.lago.dev unresolved); exit 6. In a scratch repo with certs and stubs: 3 FAIL, cert lines OK |
| `scripts/selfhost-preflight.sh` | self-host `.env` audit without printing values: line hygiene parsed like compose (multi-line quoted values, unquoted wraps, unterminated quotes), placeholder secrets, RSA base64 → PEM → `openssl rsa`, variant checks, compose parse | `.claude/skills/run-and-operate/scripts/selfhost-preflight.sh --variant production .env` | fixtures (root unless noted): empty `.env` 6 FAIL; R2 snippet 0 FAIL; multi-line raw PEM in quotes 1 FAIL (`is a raw PEM`); base64 wrapped inside quotes 0 FAIL + 1 WARN; base64 wrapped unquoted 2 FAIL; production `.env` as deploy.sh writes it (4 `✅ … is already set` lines) 10 FAIL incl. `line 2: not KEY=VALUE` and compose `line 2: unexpected character`; light without LAGO_DOMAIN 1 FAIL |
| `scripts/partman-check.sql` | read-only partman/`enriched_events` health: availability, preload, bgw, table kind/columns/partitions, part_config, pg_cron job, verdict lines | `psql "postgres://lago:lago@localhost:5432/lago" -X -q -f .claude/skills/run-and-operate/scripts/partman-check.sql` | `WARN pg_partman NOT available on the server…`, `INFO pg_partman not installed…`, `INFO no public.enriched_events table…`; other states in reference/partitioning.md §5 |

Exit codes: compose-matrix 0/1/2 (ok / invalid file or missing script / usage); dev-preflight = number
of FAIL lines; selfhost-preflight = number of FAIL lines capped at 63, 64 = usage error; partman-check =
psql's status (0 even with FAIL verdicts: read the verdict lines). All are read-only and write nothing
into the repo or the skill directory.

## Provenance and maintenance

- Sources: `docker-compose.yml`, `docker-compose.dev.yml`, `deploy/*`, `docker/*`, `connectors/*`,
  `examples/agentic-ai-demo/*`, `scripts/*`, `traefik/*`, `extra/debezium_config.json`,
  `events-processor/{main.go,processors/main_processor.go,config/kafka/consumer.go,processors/events_processor/*.go,cache/consumer.go}`,
  docs (`dev_environment.md`, `database_partitioning.md`, `monitoring.md`, `architecture.md`), pinned
  lago-api (`config/routes.rb`, `config/initializers/{sidekiq,yabeda,rsa_keys}.rb`, `karafka.rb`,
  `db/structure.sql`, `db/migrate/20260109*`, `db/clickhouse_migrate/*`, `lib/tasks/events.rake`,
  `config/environments/development.rb`), commits
  `97d1f0b` `cd9f0fa` `2453945` `5dd6570` `b1e40bd` `195bbc0` `c80a7b5` `5477e39` `12b8101` `9eb8c3b`
  `b6b98c8` `d9c32b6` `8f8334e`, Docker Hub layer history of `getlago/postgres-partman:15.0-alpine`
  (hub.docker.com tags API), public getlago/lago-helm-charts @d473b1e (external).
- Re-verify (one line each; `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`,
  `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`):
  - `git ls-tree HEAD api front` → `591ae90…` / `0c5e539…` (as of 2026-10-01)
  - `grep -n 'image: getlago/api' docker-compose.yml deploy/*.yml` → root `v1.53.0`, deploy `v1.27.1`
  - `.claude/skills/run-and-operate/scripts/compose-matrix.sh --brief | grep -E 'RESULT|no profile \(25\)'` → both lines
  - `.claude/skills/run-and-operate/scripts/compose-matrix.sh --check-scripts deploy/docker-compose.production.yml | grep MISSING` → pdf-worker
  - `docker compose -f deploy/docker-compose.local.yml up --profile all --dry-run 2>&1 | tail -1` → `unknown flag: --profile`
  - `grep -n 'pg_partman_bgw' scripts/postgresql.conf docker-compose.yml` → only `scripts/postgresql.conf`
  - `sed -n '/^CREATE TABLE public.enriched_events (/,/^PARTITION/p' "$API/db/structure.sql" | grep -c '^    '` → 18
  - `grep -n 'PollRecords\|cgName :=' events-processor/config/kafka/consumer.go` → `10000`, `"%s_%s"`
  - `grep -n 'lago_evp_' events-processor/cache/consumer.go` → `:27`
  - `grep -n 'Prometheus::Exporter\|Yabeda' "$API/config/routes.rb"` → `:6`, `:10`
  - `ls "$API/scripts" | grep pdf` → `start.pdfs.worker.sh` only
  - `git -C "$H" show 97d1f0b -- docker-compose.yml | grep '^[-+] *image:'` → `-  image: postgres:14-alpine`, `+  image: getlago/postgres-partman:15.0-alpine`
  - `sed -n 10,17p "$API/config/initializers/rsa_keys.rb"` → `Base64.decode64`, `Private key is blank`, `OpenSSL::PKey::RSA.new`
  - `grep -n 'address:' "$API/config/environments/development.rb"` → `"mailhog"` (dev service is `mailpit`; as of 2026-10-01)
  - `curl -sS https://hub.docker.com/v2/repositories/getlago/postgres-partman/tags/15.0-alpine/images | jq -r '.[0].layers[].instruction' | grep -E 'PG_VERSION=|PARTMAN_VERSION|CMD'` → `PG_VERSION=15.0`, `PARTMAN_VERSION=v5.4.0`, last CMD `["postgres"]` (no CMD after the partman layer)
- Update triggers: a release bump (image tags, `docker/Dockerfile` ARGs); any edit to a compose file,
  `deploy/`, `docker/`, `scripts/`, `traefik/`, `.env.development.default`; a lago-api pin move (scripts,
  routes, migrations, `structure.sql`, Karafka routing); changes to events-processor startup, consumer or
  cache code; owner decisions on OPEN DECISION OD-1 (memory cache) or OD-2 (delivery contract); edits to
  `docs/database_partitioning.md` or `docs/monitoring.md`.
