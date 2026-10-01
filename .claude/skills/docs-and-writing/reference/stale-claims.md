# Stale-claim register

Read this before you edit, quote or trust a doc of record, and when `doc-drift-check.sh` prints a
line you need to act on. Every entry is a doc claim that contradicts the code, the config or another
doc. Each one was verified on 2026-10-01 against repo HEAD `5308258` (+ the skills-only commit
`08065ef`), lago-api at the pinned `591ae90` (`$API`), and the full-history clone (`$H`).

How to use an entry:

<!-- evidence-check: off (procedure) -->
1. Re-run the check first: `.claude/skills/docs-and-writing/scripts/doc-drift-check.sh --only SC-NN`.
   `STALE` means the entry still holds. Anything else, follow the hint on the line.
2. Paste the "Corrected text" block, adjusting only line wrapping.
3. Ship it as its own PR in the class shown (C0 = docs only; see `change-control`). Mention the
   SC-ID and paste the `doc-drift-check.sh --only SC-NN` output from before and after (`STALE` then
   `PASS`) in the PR body.
4. When it merges, mark the entry `FIXED <date> <sha>` in the table below. Do not delete it.
   The check keeps guarding against a regression.
<!-- evidence-check: on -->

Sources: `$API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`,
`H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`.

## Summary (38 entries; doc-drift-check today: STALE=36 OPEN=1 KNOWN=1)

| ID | Where (as of 2026-10-01) | Wrong claim, short | Fix class | Status |
|---|---|---|---|---|
| SC-01 | `events-processor/CLAUDE.md:7,10` | direct `go build`/`go test` "won't work locally"; always `lago exec` | C0 (wording depends on OD-5) | STALE |
| SC-02 | `events-processor/README.md:6` | the service needs ClickHouse | C0 | STALE |
| SC-03 | `events-processor/README.md:13-16` | plain `go build -o event_processors .` | C0 | STALE |
| SC-04 | `events-processor/README.md:38` | `ENV=production` disables `.env` loading | C0 | STALE |
| SC-05 | `events-processor/README.md:47,57-59` | `LAGO_REDIS_CACHE_*` required/optional | C0 | STALE |
| SC-06 | `events-processor/README.md:41,43` | topic examples `events_raw`, `events_charge_in_advance` | C0 | STALE |
| SC-07 | `events-processor/README.md:68` | `USE_MEMORY_CACHE`; prefix example `lago_dbz` | C0 | STALE |
| SC-08 | `events-processor/README.md:56` | `LAGO_REDIS_STORE_TLS` default false | C0 | STALE |
| SC-09 | `events-processor/README.md:40` | multi-broker example (breaks memory-cache consumers) | C0 doc; C3 code (OD-1) | STALE |
| SC-10 | `events-processor/README.md:32-68` | env tables omit 8 variables; required ones unmarked | C0 | STALE |
| SC-11 | `events-processor/Dockerfile.staging:20-22` | lago-expression: "bump both together" | C0 comment (C5 file) | STALE |
| SC-12 | `docs/dev_environment.md:154` | `LAGO_CLICKHOUSE_ENABLED=false` disables ClickHouse | C0 | STALE |
| SC-13 | `docs/dev_environment.md:158` | env files "are not interpolated" | C0 | STALE |
| SC-14 | `docs/dev_environment.md:97-106` | `/etc/hosts` list | C0 | STALE |
| SC-15 | `docs/dev_environment.md:116-137` (absent) | external volume `lago_front_pnpm_store` never mentioned | C0 | STALE |
| SC-16 | `docs/dev_environment.md:266-278` | commit the gitlink, `git push origin main` | C0 | STALE |
| SC-17 | `docs/dev_environment.md:43-71` | `lago` alias, silent on the lago-cli binary | C0 | STALE |
| SC-18 | `docs/architecture.md:89,218` | `SIDEKIQ_PDF` | C0 | STALE |
| SC-19 | `docs/architecture.md:333` | flagged-subscription refresh every 1 min, one env var | C0 | STALE |
| SC-20 | `docs/architecture.md:232` | events-processor "Processes and aggregates" | C0 | STALE |
| SC-21 | `docs/architecture.md:546-548` | glossary inverts Customer / User | C0 | STALE |
| SC-22 | `docs/architecture.md:66-67,132,146-148,163,184` | retry and timeout semantics | C0 | STALE |
| SC-23 | `docs/architecture.md:58,212`; `docs/monitoring.md:144-163` | `wallets` queue deprecated / in default worker | C0 | STALE |
| SC-24 | `docs/architecture.md:495-509,521` | `RSA_PRIVATE_KEY` | C0 | STALE |
| SC-25 | `docs/architecture.md:527-540` | "Usage event" / "Billing creation" placeholders | C0 | STALE |
| SC-26 | `docs/arch_diagram.png` (`docs/architecture.md:28`) | diagram omits EP->Postgres/Redis and Debezium | C0 | STALE |
| SC-27 | `docs/database_partitioning.md:58-76,99-102` | 15-column DDL; step 5 `INSERT ... SELECT *` fails | C0 | STALE |
| SC-28 | `docs/database_partitioning.md:251` | "No additional setup" with default compose | C0 | STALE |
| SC-29 | `docs/monitoring.md:33,47-68,109` | metrics only via private `lago-sidekiqs` | C0 | STALE |
| SC-30 | `deploy/README.md:21-165` (14 commands), `:92-95` | `docker compose up --profile X` | C0 | STALE |
| SC-31 | `deploy/deploy.sh:106,169-190,288-299,314` | code-vs-code: 3 defects | C6 | STALE |
| SC-32 | `docker/README.md:40` | default `DATABASE_URL` password `lago` | C0 | STALE |
| SC-33 | `connectors/README.md:7-22,49-65` | event format and Kinesis table | C0 doc; C4 mapping | STALE |
| SC-34 | `.env.development.default:3` (`README.md:106`) | `LAGO_MCP_SERVER_URL` -> `mcp-server`, defined only in lago-agent-toolkit's overlay, undocumented here | C6 | STALE |
| SC-35 | `PULL_REQUEST_TEMPLATE.md:14` | `pnpm test` must pass | C0 | STALE |
| SC-36 | `PULL_REQUEST_TEMPLATE.md:8`, `CONTRIBUTING.md:170` vs `$API/AGENTS.md:52` | branch prefixes MUST; 72 vs 50 | C0 after OD-7 | OPEN DECISION OD-7 |
| SC-37 | `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:11` | ZSET score is "the event timestamp" | lago-api PR | STALE |
| SC-38 | commit `5308258` message | AWS account id kept out of public repos | immutable | KNOWN |

## Entries

### SC-01 `events-processor/CLAUDE.md:7,10`: the Docker-only build rule

- **Claim** (`events-processor/CLAUDE.md:7,10`): "Direct `go build` / `go test` won't work locally due to CGO dependencies. Always use
  `lago exec` to run commands inside the service container." The test command at `:7` is
  `lago exec events-processor go test ./...`.
- **Truth (VERIFIED 2026-10-01):**
  - Both commands work on the host once `libexpression_go.so` is on the link and loader paths.
    `.claude/skills/build-and-env/scripts/ep-test.sh` gave `ok` for all 6 test packages in 5-7 s
    with a warm cache (2026-10-01).
  - CI does the same on the host, with no Docker
    (`.github/workflows/events-processor-tests.yml:40-64`: builds lago-expression `v0.2.0`, runs
    `go test -v ./...`).
  - Without the library, `go build` fails with `cannot find -lexpression_go`.
  - `lago` is a shell alias (`docs/dev_environment.md:53`) that agent shells never expand
    (`bash -c 'alias lago=echo; lago hi'` exits 127, "command not found").
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text** (replace the whole file):

  ````markdown
  # Events Processor

  ## Build & Test

  `go build` and `go test` link the lago-expression Rust library (`libexpression_go.so`, cgo).
  Only `processors/events_processor` needs it; `config/database` tests need Postgres at `$DATABASE_URL`.

  Without Docker (the same shape as CI, `.github/workflows/events-processor-tests.yml`), from the repo root:

  ```shell
  source .claude/skills/build-and-env/scripts/ep-env.sh   # builds libexpression_go.so at the tag in events-processor/Dockerfile; exports CGO_LDFLAGS, LD_LIBRARY_PATH
  .claude/skills/build-and-env/scripts/ep-test.sh          # go test -count=1 ./...
  ```

  Manual equivalent: build github.com/getlago/lago-expression at the tag in `events-processor/Dockerfile`
  (`cd expression-go && cargo build --release`), then
  `export CGO_LDFLAGS="-L<lago-expression>/target/release" LD_LIBRARY_PATH="<lago-expression>/target/release"`
  and run `go test ./...` in `events-processor/`.

  With the dev stack running:

  ```shell
  docker compose -f "$LAGO_PATH/docker-compose.dev.yml" exec events-processor go test ./...
  ```

  `lago exec events-processor go test ./...` is the same command through the `lago` shell alias of
  docs/dev_environment.md. Non-interactive shells (scripts, CI, coding agents) do not expand aliases;
  add `-T` to `exec` when there is no TTY.
  ````

- **Class:** C0. Which local gate is policy is OPEN DECISION OD-5 (owner). The default is that the
  Docker-free recipe is accepted, so the text above presents both and mandates neither. The
  `docker compose ... exec` line cannot run in a daemon-less sandbox. It is the alias expansion of
  `docs/dev_environment.md:53`.
  <!-- evidence-check: on -->

### SC-02 `events-processor/README.md:6`: "configured with Clickhouse"

- **Claim** (`events-processor/README.md:6`): "This service need to be configured with Clickhouse and Redpanda. Please contact us for
  further informations."
- **Truth (VERIFIED):**
  - There is no ClickHouse dependency or import. `grep -i clickhouse events-processor/go.mod`
    prints nothing, and the only Go mention is a comment (`events-processor/models/stores.go:97`).
  - ClickHouse ingests the produced topics through Kafka-engine tables
    (`$API/db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:9`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  The service consumes raw events from Kafka (Redpanda in dev), reads Postgres (or, with
  `LAGO_USE_MEMORY_CACHE=true`, an in-memory cache fed by Debezium CDC topics), and produces enriched
  events back to Kafka. It has no ClickHouse client: ClickHouse ingests the `events_enriched` topic
  downstream.
  ```

- **Class:** C0.
  <!-- evidence-check: on -->

### SC-03 `events-processor/README.md:13-16`: plain `go build`

- **Claim** (`events-processor/README.md:13-16`): under "With the docker compose environment": `go build -o event_processors .` then
  `./event_processors`.
- **Truth (VERIFIED):**
  - Without `CGO_LDFLAGS` the build fails with
    `/usr/bin/ld: cannot find -lexpression_go: No such file or directory`.
  - With the library on the path it builds a 58,101,160-byte binary
    (`source .claude/skills/build-and-env/scripts/ep-env.sh`, then
    `go build -o "$(mktemp -d)/event_processors" .`). Run with no env, the binary panics at once with
    `brokers not found` (`processors/main_processor.go:106`).
  - `event_processors` is not gitignored: `git check-ignore -v events-processor/event_processors`
    exits 1. Only the name `events-processor` is (`events-processor/.gitignore:24`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ````markdown
  ## How to run it

  The binary links `libexpression_go.so` (lago-expression). From the repo root:

  ```shell
  source .claude/skills/build-and-env/scripts/ep-env.sh
  cd events-processor && go build -o "${TMPDIR:-/tmp}/event_processors" .
  LAGO_KAFKA_BOOTSTRAP_SERVERS=localhost:19092 ... "${TMPDIR:-/tmp}/event_processors"   # see Configuration; missing brokers => panic "brokers not found"
  ```

  In the dev stack the `events-processor` service builds and runs it for you
  (`docker compose -f "$LAGO_PATH/docker-compose.dev.yml" up -d events-processor`).
  ````

- **Class:** C0. Building outside the repo keeps the 58 MB binary out of `git status`
  (change-control N10).
  <!-- evidence-check: on -->

### SC-04 `events-processor/README.md:38`: `ENV` and `.env`

- **Claim** (`events-processor/README.md:38`): `ENV` "Set as `production` to not load `.env` file".
- **Truth (VERIFIED):**
  - No dotenv code exists: `grep -rni dotenv --include=*.go --include=go.mod events-processor`
    prints nothing.
  - `ENV` defaults to `development`, which sets the debug log level (`events-processor/main.go:31-35`).
  - `ENV` is also the Sentry environment (`main.go:55`) and the legacy default for Redis TLS
    (`processors/main_processor.go:85`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  | ENV | `development` (default) logs at debug level; also used as the Sentry environment. `production` turns Redis TLS on unless `LAGO_REDIS_STORE_TLS` is set to a valid boolean. No `.env` file is loaded |
  ```

- **Class:** C0.
  <!-- evidence-check: on -->

### SC-05 `events-processor/README.md:47,57-59`: dead Redis cache variables

- **Claim** (`events-processor/README.md:47,57-59`): `LAGO_REDIS_CACHE_URL` is required (`:47`). `LAGO_REDIS_CACHE_DB`, `_PASSWORD` and
  `_TLS` are optional (`:57-59`).
- **Truth (VERIFIED):**
  - The four names are only declared as constants (`processors/main_processor.go:40-43`). Nothing
    reads them.
  - `2fd8e8b` (#766, 2026-09-14) removed their last user.
  - `d9c32b6` (2026-09-18) edited this table four days later and left them in.
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** delete the four `LAGO_REDIS_CACHE_*` rows. Keep the `LAGO_REDIS_STORE_*` rows:
  they are the only Redis variables the code reads (`processors/main_processor.go:79-91`).
- **Class:** C0. Removing the dead constants is a separate C2 change.
  <!-- evidence-check: on -->

### SC-06 `events-processor/README.md:41,43`: topic name examples

- **Claim** (`events-processor/README.md:41,43`): examples `events_raw` (`:41`) and `events_charge_in_advance` (`:43`).
- **Truth (VERIFIED):** dev uses `events-raw` (hyphen) and `events_charged_in_advance`
  (`.env.development.default:78,85`; topics created at `docker-compose.dev.yml:397-405`). A
  consumer configured from the README example reads a topic that does not exist in dev.
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** "(dev: `events-raw`)" and "(dev: `events_charged_in_advance`)".
- **Class:** C0.
  <!-- evidence-check: on -->

### SC-07 `events-processor/README.md:68`: memory-cache variable name and prefix

- **Claim** (`events-processor/README.md:68`): "Mandatory if USE_MEMORY_CACHE is set to true, debezium kafka topic prefix (eg:
  `lago_dbz`)".
- **Truth (VERIFIED):**
  - The variable is `LAGO_USE_MEMORY_CACHE`. Only the literal value `true` enables it
    (`events-processor/main.go:23,67`).
  - The repo's Debezium config uses `"topic.prefix": "lago_proc_cdc"`
    (`extra/debezium_config.json:47`). Whether production runs memory-cache mode is OPEN DECISION
    OD-1 (owner).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  | LAGO_DEBEZIUM_TOPIC_PREFIX | Required when `LAGO_USE_MEMORY_CACHE=true` (only the exact value `true` enables the cache): Debezium topic prefix, `<prefix>.public.<table>` (repo config `extra/debezium_config.json`: `lago_proc_cdc`) |
  ```

- **Class:** C0.
  <!-- evidence-check: on -->

### SC-08 `events-processor/README.md:56`: Redis store TLS default

- **Claim** (`events-processor/README.md:56`): `LAGO_REDIS_STORE_TLS` "(default: false)".
- **Truth (VERIFIED):** the default is `ENV == "production"`
  (`processors/main_processor.go:85,91`: `legacyTLS := os.Getenv(envEnv) == "production"`;
  `GetEnvAsBool(envLagoRedisStoreTLS, legacyTLS)`). lago-api reads a different name,
  `LAGO_REDIS_STORE_SSL` (see `config-and-flags`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** "(default: `true` when `ENV=production`, else `false`; lago-api uses
  `LAGO_REDIS_STORE_SSL` for the same Redis)".
- **Class:** C0.
  <!-- evidence-check: on -->

### SC-09 `events-processor/README.md:40`: multi-broker example

- **Claim** (`events-processor/README.md:40`): example `"redpanda:9092,kafka:9092"`.
- **Truth (VERIFIED by reading code):**
  - The main consumer splits on commas (`utils/env.go:22-33`).
  - The memory-cache consumers pass the raw string as one seed broker
    (`cache/consumer.go:28,31`: `kgo.SeedBrokers(brokers)`). A list therefore works in DB mode but
    not with `LAGO_USE_MEMORY_CACHE=true`.
  - Production impact depends on OPEN DECISION OD-1 (owner). Runtime behaviour with a list:
    see `architecture-contract` (weak points).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** "Comma-separated list, no quotes, e.g. `redpanda:9092`. With
  `LAGO_USE_MEMORY_CACHE=true` use a single broker (the cache consumers do not split the list)."
- **Class:** C0 for the doc. The code fix is a C3 change owned by `architecture-contract` /
  `event-accounting-campaign`.
  <!-- evidence-check: on -->

### SC-10 `events-processor/README.md:32-68`: incomplete env tables

- **Claim** (`events-processor/README.md:32-68`, by omission): the two tables are the full configuration.
- **Truth (VERIFIED):**
  - The code also reads `SENTRY_DSN` (`main.go:22,54`), `TRACING_PROVIDER`, `KAFKA_TRACING_ENABLED`,
    `DD_TRACE_ENABLED`, `DD_AGENT_HOST`, `DD_TRACE_AGENT_PORT` (default 8126) and `DD_SERVICE_NAME`
    (`config/tracing/tracer.go:26-27,35-38,138`), plus `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS`
    (default 200, `processors/main_processor.go:29,134`).
  - The tables do not say which variables are fatal. An empty `LAGO_KAFKA_BOOTSTRAP_SERVERS`
    panics with "brokers not found". An empty producer topic fails with "`<VAR>` variable is
    required" (`main_processor.go:56-58`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** add rows for the 8 variables and mark the required ones. Take the semantics
  from `config-and-flags` (it owns the env registry); do not re-derive them here.
- **Class:** C0.
  <!-- evidence-check: on -->

### SC-11 `events-processor/Dockerfile.staging:20-22`: "bump both together"

- **Claim** (`events-processor/Dockerfile.staging:20-22`): pinned to v0.2.0 "to match the upstream events-processor/Dockerfile; bump both together".
- **Truth (VERIFIED):** the lago-expression ref lives in **4** places: `events-processor/Dockerfile:5`,
  `events-processor/Dockerfile.dev:5`, `events-processor/Dockerfile.staging:23`,
  `.github/workflows/events-processor-tests.yml:45`. `5077151` (#666) bumped the three that existed
  then (change-control N3).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```dockerfile
  # events-processor binary. Pinned to v0.2.0; the same ref is in Dockerfile, Dockerfile.dev and
  # .github/workflows/events-processor-tests.yml - bump all four together (change-control N3).
  ```

- **Class:** C0 wording inside a C5 file. Run the `change-control` pin-sync check in the same PR.
  <!-- evidence-check: on -->

### SC-12 `docs/dev_environment.md:154`: disabling ClickHouse

- **Claim** (`docs/dev_environment.md:154`): "If you want to disable Clickhouse, you can set `LAGO_CLICKHOUSE_ENABLED=false`".
- **Truth (VERIFIED):**
  - lago-api tests `ENV["LAGO_CLICKHOUSE_ENABLED"].present?`
    (`$API/app/services/events/stores/store_factory.rb:10`; `$API/clock.rb:210`), so `"false"`
    means enabled.
  - An empty value in the later env file wins: a scratch compose with `X=true` then `X=` renders
    `X: ""` (`docker compose -f <scratch>.yml config`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  _Example:_ To disable ClickHouse, set `LAGO_CLICKHOUSE_ENABLED=` (empty) in your `.env.development`.
  lago-api only checks that the variable is non-empty, so `LAGO_CLICKHOUSE_ENABLED=false` still enables it.
  ```

- **Class:** C0. The general boolean trap is owned by `config-and-flags`.
  <!-- evidence-check: on -->

### SC-13 `docs/dev_environment.md:158`: interpolation

- **Claim** (`docs/dev_environment.md:158`): "the docker `.env` files are not interpolated so make sure all values are static (no
  `ENV_VAR=${MY_VAR_FROM_SHELL}`)".
- **Truth (VERIFIED):**
  - `.env.development.default:24` sets
    `DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}`.
  - `docker compose -f docker-compose.dev.yml config api` renders it as
    `postgresql://lago:changeme@db:5432/lago`.
  - A scratch env_file with `C=${MY_VAR_FROM_SHELL}`, rendered with `MY_VAR_FROM_SHELL=fromshell`
    in the environment, gives `C: fromshell` (`docker compose -f <scratch>.yml config`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  Values in `.env.development.default` and `.env.development` are interpolated by Docker Compose:
  `${VAR}` can reference a variable defined earlier in the same file (see `DATABASE_URL`) or one from
  your shell. Check the result with `docker compose -f "$LAGO_PATH/docker-compose.dev.yml" config <service>`.
  ```

- **Class:** C0.
  <!-- evidence-check: on -->

### SC-14 `docs/dev_environment.md:97-106`: `/etc/hosts` list

- **Claim** (`docs/dev_environment.md:97-106`): the list of local domains, which includes `license.lago.dev` (`:103`).
- **Truth (VERIFIED):**
  - The `Host()` rules in `docker-compose.dev.yml` are traefik, app, webhook, api, pdf, mail,
    console (`docker-compose.dev.yml:430`, Redpanda Console) and pghero (`docker-compose.dev.yml:514`).
  - No dev service serves `license.lago.dev`. getlago/lago-license is not publicly reachable
    (`git ls-remote https://github.com/getlago/lago-license` asks for credentials, 2026-10-01).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```shell
  # Lago local domains
  127.0.0.1 traefik.lago.dev
  127.0.0.1 api.lago.dev
  127.0.0.1 app.lago.dev
  127.0.0.1 pdf.lago.dev
  127.0.0.1 mail.lago.dev
  127.0.0.1 webhook.lago.dev
  127.0.0.1 console.lago.dev
  127.0.0.1 pghero.lago.dev
  ```

- **Class:** C0. Regenerate the list with
  ``grep -oE 'Host\(.[a-z0-9.-]+' docker-compose.dev.yml | cut -c7- | sort -u``
  (8 names as of 2026-10-01; the pattern avoids backticks, which GNU grep reads as an anchor
  when escaped).
  <!-- evidence-check: on -->

### SC-15 `docs/dev_environment.md`: the external pnpm volume

- **Claim** (`docs/dev_environment.md:116-137`, by omission): the "Running the app" steps start `front` with no prerequisite.
- **Truth (VERIFIED by reading):**
  - `lago_front_pnpm_store` is declared `external: true` (`docker-compose.dev.yml:11-12`) and
    mounted by `front` (`:103`). `195bbc0` added it.
  - Compose does not create external volumes. That `up front` fails without the volume is
    UNVERIFIED here (no daemon). It is standard Compose behaviour.
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text** (before "Start the dependencies"):

  ````markdown
  The `front` service mounts an external pnpm store volume. Create it once:

  ```shell
  docker volume create lago_front_pnpm_store
  ```
  ````

- **Class:** C0.
  <!-- evidence-check: on -->

### SC-16 `docs/dev_environment.md:266-278`: "Updating a reference"

- **Claim** (`docs/dev_environment.md:266-278`): to update a submodule reference, check out a commit in `api/`, `git add api`,
  `git commit`, `git push origin main`.
- **Truth (VERIFIED):**
  - Gitlinks move only in a release bump PR (change-control N1). Example: the v1.53.0 bump is
    `ba292b6` "Bump version to v1.53.0 (#792)".
  - Pushing to `main` bypasses review (change-control N2).
  - An accidental gitlink move shipped once already: `12b8101`, reverted by `647de3e` (#620).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  ### Updating a reference

  The `api` and `front` pointers move only in a release bump PR. To try another lago-api commit
  locally, check it out inside `api/` and do not commit the umbrella repo. Before any commit here,
  run `git diff --cached --submodule`; if `api` or `front` shows up, unstage it with
  `git restore --staged api front`.
  ```

- **Class:** C0. Release mechanics: `release-and-images`.
  <!-- evidence-check: on -->

### SC-17 `docs/dev_environment.md:43-71`: the `lago` name

- **Claim** (`docs/dev_environment.md:43-71`, by omission): `lago` is safe to use as a command name, in 15 command lines of this doc
  (`grep -cE '^\s*lago ' docs/dev_environment.md` -> 15) plus the `lago exec <service> <command>` hint at `:140`, and
  in `events-processor/README.md:23,29`, `events-processor/CLAUDE.md:7`, `$API/AGENTS.md:8-9`.
- **Truth (VERIFIED):**
  - `README.md:62,160` promotes getlago/lago-cli. Its binary is also named `lago`
    (`brew install getlago/tap/lago`). Its commands at `49a7a03` (2026-09-17) include no `exec`
    and no `up`.
  - Non-interactive bash does not expand aliases: `bash -c 'alias lago=echo; lago hi'` exits 127.
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text** (after the shell snippets):

  ```markdown
  > [!WARNING]
  > `lago` here is a shell alias. The Lago CLI (getlago/lago-cli) installs a binary that is also called
  > `lago` and has no `exec` or `up` command. Scripts, CI and coding agents do not load shell aliases.
  > In those, write the expansion: `docker compose -f "$LAGO_PATH/docker-compose.dev.yml" <command>`.
  ```

- **Class:** C0. Renaming the alias is the owner's call (not an OD yet; route via
  `change-control`).
  <!-- evidence-check: on -->

### SC-18 `docs/architecture.md:89,218`: `SIDEKIQ_PDF`

- **Claim** (`docs/architecture.md:89,218`): the PDF worker is enabled with `SIDEKIQ_PDF`.
- **Truth (VERIFIED):** the code reads `SIDEKIQ_PDFS` (`$API/app/jobs/invoices/generate_pdf_job.rb:6`
  and 10 other jobs: `grep -rln SIDEKIQ_PDFS "$API/app/jobs" | wc -l` -> 11;
  `.env.development.default:50`; commented example at `docker-compose.yml:68`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** replace `SIDEKIQ_PDF` with `SIDEKIQ_PDFS` on both lines.
- **Class:** C0.
  <!-- evidence-check: on -->

### SC-19 `docs/architecture.md:333`: flagged-subscription refresh

- **Claim** (`docs/architecture.md:333`): "Refresh Flagged Subscriptions | Every 1 minute | ... | Requires `LAGO_REDIS_STORE_URL`".
- **Truth (VERIFIED):** `$API/clock.rb:209-215` schedules `Clock::ConsumeSubscriptionRefreshedQueueJob`
  `every(10.seconds, ...)`, only when both `LAGO_REDIS_STORE_URL` and `LAGO_CLICKHOUSE_ENABLED` are
  present.
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  | Refresh Flagged Subscriptions | Every 10 seconds | Refreshes usage of subscriptions the events-processor flagged in the Redis sorted set `subscription_refreshed_v2` | Scheduled only when both `LAGO_REDIS_STORE_URL` and `LAGO_CLICKHOUSE_ENABLED` are non-empty |
  ```

- **Class:** C0.
  <!-- evidence-check: on -->

### SC-20 `docs/architecture.md:232`: "Processes and aggregates"

- **Claim** (`docs/architecture.md:232`): Events Processor Worker "Processes and aggregates usage events".
- **Truth (VERIFIED):** it enriches events and produces them to Kafka. It has no ClickHouse client
  (SC-02). lago-api reads `events_enriched` from ClickHouse when it computes usage
  (`$API/app/services/events/stores/clickhouse_store.rb:9,27`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  | **Events Processor** (`events-processor/`, Go) | Enriches raw events from the raw Kafka topic (billable metric, subscription, expression) and produces them to `events_enriched`, `events_charged_in_advance` and `events_dead_letter`; flags subscriptions for usage refresh in Redis. It does not aggregate: ClickHouse ingests `events_enriched` and lago-api aggregates at query time | Conditional | Required when events go through Kafka and ClickHouse |
  ```

- **Class:** C0.
  <!-- evidence-check: on -->

### SC-21 `docs/architecture.md:546-548`: glossary

- **Claim** (`docs/architecture.md:546-548`): "Customer" is the organization operating billing; "User" is the billed party.
- **Truth (VERIFIED):**
  - `User` is a login account: `has_secure_password`, organizations through memberships
    (`$API/app/models/user.rb:3-15`).
  - `Customer` is the billed party: `belongs_to :organization`, subscriptions, invoices
    (`$API/app/models/customer.rb:62-69`).
  - `Organization` owns customers, plans, billable metrics and invoices
    (`$API/app/models/organization.rb:45-61`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  **Organization**: the Lago tenant that runs billing. It owns customers, plans, billable metrics and invoices.

  **User**: a person who signs in to the Lago UI. A user belongs to one or more organizations through memberships.

  **Customer**: the party an organization bills. A customer belongs to one organization and has subscriptions and invoices.
  ```

- **Class:** C0. Keep in step with the `domain-reference` glossary.
  <!-- evidence-check: on -->

### SC-22 `docs/architecture.md:66-67,132,146-148,163,184`: retry and timeout

- **Claim** (`docs/architecture.md:66-67,132,146-148,163,184`): "Retry: 1 attempt" (`:67`); "Job Fails -> Retry #1 (with exponential backoff)" (`:184`);
  "Timeout: 25 seconds" / "Jobs timeout after 25 seconds" (`:66,132`) next to "Jobs do not have
  execution timeout" (`:163`). Only `:146-148` is right.
- **Truth (VERIFIED):**
  - Sidekiq-level retries are 0: `config[:max_retries] = 0` (`$API/config/initializers/sidekiq.rb:70`)
    and `sidekiq_options retry: 0` (`$API/app/jobs/application_job.rb:4`).
  - ActiveJob retries `RetriableError` with `wait: :polynomially_longer, attempts: 20`
    (`application_job.rb:11`). Jobs add their own `retry_on` (e.g.
    `$API/app/jobs/customers/refresh_wallet_job.rb:16`).
  - `timeout: 25` sits in `$API/config/sidekiq/sidekiq.yml:2`. In Sidekiq that key is the shutdown
    grace period. That meaning is UNVERIFIED for the pinned Sidekiq version.
  - `retry: 1` sits at `$API/config/sidekiq/sidekiq.yml:3` (and line 3 of all 12
    `config/sidekiq/sidekiq*.yml`). It is the likely source of the doc's "Retry: 1 attempt". Whether
    that YAML key changes anything for jobs that inherit `sidekiq_options retry: 0` is UNVERIFIED
    (not exercised here). Do not cite it as proof that jobs retry once.
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  - **Retry**: Sidekiq retries are off (`config[:max_retries] = 0`, `sidekiq_options retry: 0`). Retries
    come from ActiveJob: `ApplicationJob` retries `RetriableError` up to 20 attempts with polynomially
    growing waits, and individual jobs declare their own `retry_on`. Other failures are not retried.
  - **Timeout**: no per-job execution timeout. `timeout: 25` in `config/sidekiq/*.yml` is the shutdown
    grace period.
  ```

  In the "Error Recovery Flow" block, replace "Retry #1 (with exponential backoff)" with "Retried
  only if the job declares `retry_on` for this error (ActiveJob)".
- **Class:** C0.
  <!-- evidence-check: on -->

### SC-23 `wallets` queue: `docs/architecture.md:58,212`; `docs/monitoring.md:144-163`

- **Claim** (`docs/architecture.md:58,212`): `wallets` is "(deprecated - jobs migrated to other queues)" (`architecture.md:58`) and part
  of the Default Worker list (`:212`). `monitoring.md:161` says "Default Worker (deprecated)". The same
  doc calls it live at `:93,220`.
- **Truth (VERIFIED):**
  - The default worker's queues (`$API/config/sidekiq/sidekiq.yml:4-14`) are high_priority, default,
    mailers, clock, providers, webhook, invoices, integrations, low_priority, long_running. There is
    no `wallets`.
  - `wallets` is served by `sidekiq_wallets.yml`. `Customers::RefreshWalletJob` routes there when
    `SIDEKIQ_WALLETS=true`, else to `low_priority`, or to the per-org `dedicated_wallets`
    (`$API/app/jobs/customers/refresh_wallet_job.rb:5-11`).
  - `monitoring.md` omits alerts, alerts_high_priority, analytics_low_priority,
    billing_low_priority, payments, dedicated_alerts and dedicated_wallets (`$API/config/sidekiq/*.yml`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**
  - `architecture.md:58`: `| \`wallets\` | Wallet balance refresh, only with \`SIDEKIQ_WALLETS=true\` (Wallet Worker); otherwise these jobs run on \`low_priority\` |`.
  - `:212`: drop `` `wallets`, `` from the list.
  - `monitoring.md:161`: `| \`wallets\` | Wallet Worker |`, and add rows for the 7 missing queues.
- **Class:** C0.
  <!-- evidence-check: on -->

### SC-24 `docs/architecture.md:495-509,521`: `RSA_PRIVATE_KEY`

- **Claim** (`docs/architecture.md:495-509,521`): the webhook JWT key is configured with `RSA_PRIVATE_KEY`.
- **Truth (VERIFIED):**
  - The API reads `config/keys/private.pem` if it exists, else `Base64.decode64(ENV["LAGO_RSA_PRIVATE_KEY"])`,
    and aborts at boot when the key is blank (`$API/config/initializers/rsa_keys.rb:6-15`).
  - `README.md:225` generates the key with `openssl genrsa 2048 | openssl base64 -A`.
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** heading `#### 3b. LAGO_RSA_PRIVATE_KEY (Asymmetric Signing for Webhooks)`;
  configuration line: "`LAGO_RSA_PRIVATE_KEY`: base64-encoded RSA private key on one line
  (`openssl genrsa 2048 | openssl base64 -A`), or the file `config/keys/private.pem`. The API exits at
  boot without one." At `:521`: "Uses `LAGO_RSA_PRIVATE_KEY`".
- **Class:** C0.
  <!-- evidence-check: on -->

### SC-25 `docs/architecture.md:527-540`: placeholders

- **Claim** (`docs/architecture.md:527-540`): "A detailed architecture diagram will be added to this section in a future update." It
  appears twice (`:532,540`), under the two core flows.
- **Truth (VERIFIED):** the sections have been empty since the doc was created in `870d141` (#597):
  `git -C "$H" log -S 'will be added to this section in a future update' -- docs/architecture.md`
  lists only that commit. A promise is not documentation (SKILL.md style rule S7).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text** (Usage event; each line was verified at the pin):

  ```markdown
  1. A client sends `POST /api/v1/events` (`config/routes/shared_api.rb:98` in lago-api), or a connector
     (`connectors/*.yml`) writes the event straight to the raw Kafka topic.
  2. The API validates the event. For organizations on the Postgres event store it saves the event and
     enqueues post-processing. When `LAGO_KAFKA_BOOTSTRAP_SERVERS` and `LAGO_KAFKA_RAW_EVENTS_TOPIC`
     are set, it also publishes the event to the raw topic (`Events::CreateService`, `Events::KafkaProducerService`).
  3. The events-processor (`events-processor/`) consumes the raw topic, enriches each event and produces
     it to `events_enriched`. Pay-in-advance events also go to `events_charged_in_advance`. Failures go
     to `events_dead_letter`. It flags the subscription in the Redis sorted set `subscription_refreshed_v2`.
  4. ClickHouse ingests `events_enriched` through a Kafka-engine table. lago-api reads it when it
     computes usage, consumes `events_charged_in_advance` (`EventsChargedInAdvanceConsumer` ->
     `Events::PayInAdvanceJob`), and refreshes flagged subscriptions every 10 seconds.
  ```

  For "Billing creation", the verified start of the chain is: every hour at :10 the clock enqueues
  `Clock::SubscriptionsBillerJob` (`$API/clock.rb:79-83`), which enqueues
  `Subscriptions::OrganizationBillingJob` per organization
  (`$API/app/jobs/clock/subscriptions_biller_job.rb:7-11`). Write the rest from `domain-reference`.
  Do not guess it.
- **Class:** C0.
  <!-- evidence-check: on -->

### SC-26 `docs/arch_diagram.png` (rendered at `docs/architecture.md:28`)

- **Claim** (`docs/architecture.md:28`, picture): the events-processor box has Kafka edges only. No Debezium or Kafka Connect
  box appears.
- **Truth (VERIFIED, image viewed 2026-10-01, blob `206170d`):**
  - The processor reads Postgres (`processors/main_processor.go:140`).
  - It writes Redis (`main_processor.go:88-91`).
  - With `LAGO_USE_MEMORY_CACHE=true` it consumes Debezium CDC topics (`main.go:67-80`;
    `extra/debezium_config.json`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text** (caption under the image until the PNG is redrawn):

  ```markdown
  _Not shown: the events-processor also reads Postgres (or, with `LAGO_USE_MEMORY_CACHE=true`, an
  in-memory cache fed by Debezium CDC topics) and writes the Redis sorted set `subscription_refreshed_v2`._
  ```

- **Class:** C0. The check compares the PNG blob hash, so a redrawn image flips the line to PASS.
  <!-- evidence-check: on -->

### SC-27 `docs/database_partitioning.md:58-76,99-102`: retroactive DDL

- **Claim** (`docs/database_partitioning.md:58-76,99-102`): the step 3 `CREATE TABLE` (15 columns) followed by step 5
  `INSERT INTO public.enriched_events SELECT * FROM public.enriched_events_old;`.
- **Truth (VERIFIED):**
  - The schema has 18 columns (`$API/db/structure.sql`, `CREATE TABLE public.enriched_events`).
    `operation_type`, `precise_total_amount_cents` and `target_wallet_code` were added after the
    doc (`4cba248`, 2026-02-12).
  - In a throwaway database, step 5 fails: `ERROR: INSERT has more expressions than target columns`.
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**
  - In step 3, add these three lines before `PRIMARY KEY`:
    `operation_type character varying,`, `precise_total_amount_cents numeric(40,15),`,
    `target_wallet_code character varying,`.
  - Replace step 5 with:

    ```sql
    INSERT INTO public.enriched_events (id, organization_id, event_id, transaction_id, external_subscription_id, code, "timestamp", subscription_id, plan_id, charge_id, charge_filter_id, grouped_by, value, decimal_value, enriched_at, operation_type, precise_total_amount_cents, target_wallet_code)
    SELECT id, organization_id, event_id, transaction_id, external_subscription_id, code, "timestamp", subscription_id, plan_id, charge_id, charge_filter_id, grouped_by, value, decimal_value, enriched_at, operation_type, precise_total_amount_cents, target_wallet_code
    FROM public.enriched_events_old;
    ```

  - Add one sentence: "Compare with `\d public.enriched_events_old` first: lago-api adds columns over
    time."
  - VERIFIED: the corrected DDL plus INSERT migrated a row into a throwaway database
    (`rows_migrated=1`).
- **Class:** C0.
  <!-- evidence-check: on -->

### SC-28 `docs/database_partitioning.md:251`: "No additional setup"

- **Claim** (`docs/database_partitioning.md:251`): "No additional setup is required when using the default Docker Compose configuration."
- **Truth (VERIFIED):**
  - Only `docker-compose.dev.yml:43,50` mounts `scripts/postgresql.conf` (bgw settings at
    `scripts/postgresql.conf:81,86-88`).
  - Root `docker-compose.yml:7` uses `getlago/postgres-partman:15.0-alpine` with no config mount.
    Whether that image preloads `pg_partman_bgw` by itself is UNVERIFIED.
  - `deploy/*.yml` use plain `postgres:15-alpine`. Without pg_partman the migrations skip
    partitioning (`$API/db/migrate/20260109092932_setup_partman.rb:6-8`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  Only the development stack (`docker-compose.dev.yml`) loads `scripts/postgresql.conf`, which runs
  `pg_partman_bgw` hourly. With the root `docker-compose.yml`, check `SHOW shared_preload_libraries;`:
  if `pg_partman_bgw` is missing, schedule maintenance as described above, or new rows land in
  `enriched_events_default`. The `deploy/` files use plain `postgres:15-alpine` (no pg_partman), so
  `enriched_events` is created without partitions.
  ```

- **Class:** C0.
  <!-- evidence-check: on -->

### SC-29 `docs/monitoring.md:33,47-68,109`: where metrics come from

- **Claim** (`docs/monitoring.md:33,47-68,109`): Sidekiq metrics come from a `lago-sidekiqs` service at `:3000/prometheus/metrics`, with
  config in `lago-sidekiqs/config.ru`.
- **Truth (VERIFIED):**
  - getlago/lago-sidekiqs is not publicly reachable (`git ls-remote` asks for credentials).
  - lago-api itself, with `LAGO_SIDEKIQ_WEB=true`, mounts Sidekiq Web at `/sidekiq` and the
    exporter at `/sidekiq/prometheus/metrics` (`$API/config/routes.rb:4-7`).
  - lago-api always mounts Yabeda at `/metrics` (`:10`).
  - The events-processor exposes no metrics endpoint (see `architecture-contract`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  lago-api exposes Prometheus metrics itself: Yabeda (Rails, Puma) at `/metrics`, and, when
  `LAGO_SIDEKIQ_WEB=true`, Sidekiq Web at `/sidekiq` plus the sidekiq-prometheus-exporter at
  `/sidekiq/prometheus/metrics`. The standalone `lago-sidekiqs` service described below lives in a
  private repository. The events-processor exposes no metrics endpoint (tracing only).
  ```

- **Class:** C0. `/sidekiq` exposure is a security topic (`security-and-supply-chain`).
  <!-- evidence-check: on -->

### SC-30 `deploy/README.md:21-165,92-95`: `--profile` placement

- **Claim** (`deploy/README.md:21-165,92-95`): `docker compose up --profile all` and variants (14 commands). The profile list
  (`:92-95`) omits `all-no-db`, which `:110` uses.
- **Truth (VERIFIED):**
  - `docker compose -f docker-compose.local.yml up --profile all --dry-run` gives
    `unknown flag: --profile` (exit 1). `--profile` is a global flag (`docker compose --help`).
  - All three deploy files define `all all-no-db all-no-keys all-no-pg all-no-redis`
    (`docker compose -f deploy/docker-compose.local.yml --profile '*' config --profiles`, same for
    light and production).
  - `deploy/deploy.sh:319,325` already uses the right order.
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** apply
  `sed -E 's/docker compose up( -d)? --profile ([a-z-]+)/docker compose --profile \2 up\1/'` to the
  file (it rewrites exactly the 14 commands). Add `- \`all-no-db\`: Disable both the PostgreSQL and
  the Redis services` to the list. VERIFIED: `docker compose -f deploy/docker-compose.local.yml
  --profile all-no-db config --services` lists everything except `db` and `redis`.
- **Class:** C0.
  <!-- evidence-check: on -->

### SC-31 `deploy/deploy.sh`: three defects (code vs code)

- **Claim** (`deploy/deploy.sh:106`, code):
  - `deploy/deploy.sh:106`: `running_services=$(docker compose -p "$project" ps -q &>/dev/null || ...)`.
  - `deploy/deploy.sh:169,179,190` download to `docker-compose.yml`, but `deploy/deploy.sh:314,319,325`
    run `-f docker-compose.local|light|production.yml`.
  - `deploy/deploy.sh:288-299` write `echo "${GREEN}✅ $var is already set.${NORMAL}"` into the `{ ... } > "$ENV_FILE"`
    block.
- **Truth (VERIFIED by reading):**
  - `&>/dev/null` inside `$(...)` empties the capture, so a running project is never detected
    (`deploy/deploy.sh:106-107`).
  - The `-f` file does not exist after the download (`deploy/deploy.sh:169` vs `:314`).
  - The status line lands in `.env` as a non-`KEY=value` line (`deploy/deploy.sh:295,299`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected code:**
  - `:106`: `2>/dev/null` instead of `&>/dev/null` (both alternatives).
  - `:314,319-320,325-326` (both the `docker compose` call and its `docker-compose` fallback):
    `-f docker-compose.yml`.
  - `:295`: append `>&2`.
- **Class:** C6, with review by the `run-and-operate` owner. Not a doc fix. It is registered so
  that nobody re-documents the script as working.
  <!-- evidence-check: on -->

### SC-32 `docker/README.md:40`: single-image database URL

- **Claim** (`docker/README.md:40`): `DATABASE_URL` default `postgres://lago:lago@localhost:5432/lago`.
- **Truth (VERIFIED):** `docker/runner.sh:8` generates `POSTGRES_PASSWORD=$(openssl rand -hex 16)`.
  `:71-73` build `postgresql://lago:$POSTGRES_PASSWORD@localhost:5432/lago`. Both are written to
  `/data/.env` (`:28-29,65-73`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**

  ```markdown
  | DATABASE_URL | The URL of the database | `postgresql://lago:<random>@localhost:5432/lago`; the password is generated on first start and saved in `/data/.env` |
  ```

- **Class:** C0.
  <!-- evidence-check: on -->

### SC-33 `connectors/README.md:7-22,49-65`: event format

- **Claim** (`connectors/README.md:7-22,49-65`): the event JSON has numeric `"precise_total_amount_cents": 1000` (`:20`) and no
  `organization_id`. The Kinesis variable table (`:49-65`) has no `ORGANIZATION_ID`.
- **Truth (VERIFIED by reading):**
  - All three connectors share one mapping (`connectors/http.yml:32-36`, `sqs.yml:34-38`,
    `kinesis.yml:38-42`). It forwards a number unchanged and turns anything else (including a
    string) into `"0"`. The SQS connector's unit test pins numeric output (`connectors/sqs.yml:78,89`)
    and `"0"` when the field is absent (`sqs.yml:114`).
  - The events-processor declares the field `string` (`events-processor/models/event.go:18`). A
    numeric value fails `json.Unmarshal`, and the record is committed with no DLQ
    (`processors/events_processor/processor.go:50-58`).
  - The HTTP connector reads `this.event.organization_id` (`connectors/http.yml:25`). Kinesis and SQS
    use `${ORGANIZATION_ID}` (`kinesis.yml:31`, `sqs.yml:27`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**
  - Add `"organization_id": "<lago organization id>"` (HTTP connector only) to the example.
  - Add `|ORGANIZATION_ID|Lago organization ID|Yes|` to the Kinesis table.
  - Replace the `precise_total_amount_cents` comment with: "Do not send `precise_total_amount_cents`
    through the connectors yet: a number makes the events-processor drop the event, and a string is
    replaced by `"0"`."
- **Class:** C0 for the doc. The mapping fix is C4 (`connectors/*.yml` mappings are a contract, see
  `change-control`), owned by `event-accounting-campaign` / `rails-go-parity`.
  <!-- evidence-check: on -->

### SC-34 `.env.development.default:3` (and `README.md:106`): `mcp-server`

- **Claim** (`.env.development.default:3`, config): `LAGO_MCP_SERVER_URL="http://mcp-server:3001/mcp"`,
  with no word anywhere in this repo on where `mcp-server` comes from.
- **Truth (VERIFIED 2026-10-01):**
  - No compose file in this repo defines an `mcp-server` service:
    `grep -n '^  mcp-server:' docker-compose*.yml deploy/*.yml examples/agentic-ai-demo/compose.yml`
    prints nothing. No doc mentions `LAGO_MCP_SERVER_PATH` or how to start it
    (`grep -rn 'LAGO_MCP_SERVER_PATH\|mcp-server' --exclude-dir=.claude --exclude-dir=.git .` finds
    only this line).
  - The service lives in another repo: getlago/lago-agent-toolkit `mcp/docker-compose.dev.yml:2`
    (at `832f0a8`) defines `mcp-server` on port 3001, built from `$LAGO_MCP_SERVER_PATH`, with
    `LAGO_API_URL=http://api:3000/api/v1`. It is an overlay for this dev stack:
    `LAGO_MCP_SERVER_PATH=<toolkit>/mcp docker compose -f docker-compose.dev.yml -f <toolkit>/mcp/docker-compose.dev.yml config --services`
    lists `mcp-server` (config only; starting it is not runnable in a daemon-less sandbox).
  - lago-api reads the URL for AI conversations (`$API/app/services/ai_conversations/stream_service.rb:76`).
  - `README.md:106` ("connect this agent to Lago's local MCP server") is ambiguous rather than
    false: getlago/lago-agent-toolkit can be pointed at a self-hosted URL ("For self-hosted Lago,
    replace `LAGO_API_URL`", its README at `832f0a8`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:**
  - `.env.development.default:3`: add a comment line above it:
    `# mcp-server is not defined in this repo: it comes from getlago/lago-agent-toolkit mcp/docker-compose.dev.yml (add it with a second -f and LAGO_MCP_SERVER_PATH)`.
  - `README.md:106`: "Then offer to connect this agent to the Lago MCP server
    (getlago/lago-agent-toolkit) with `LAGO_API_URL` set to this local API."
- **Class:** C6 (env file) + C0 (README).
  <!-- evidence-check: on -->

### SC-35 `PULL_REQUEST_TEMPLATE.md:14`: `pnpm test`

- **Claim** (`PULL_REQUEST_TEMPLATE.md:14`): "`pnpm test` doesn't throw any error."
- **Truth (VERIFIED):** `git ls-files '*package.json'` prints nothing. The line came from a front-end
  repo (`55644b8` changed it from `npm test` to `pnpm test`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** "d. The checks for your change class pass (see `change-control`); for
  `events-processor/`, `go test ./...` passes."
- **Class:** C0 (the template rewrite belongs with SC-36).
  <!-- evidence-check: on -->

### SC-36 contributor rules: OPEN DECISION OD-7 (owner)

- **Claim** (`PULL_REQUEST_TEMPLATE.md:8`):
  - Branches "MUST" start with `fix/` or `feature/` (`PULL_REQUEST_TEMPLATE.md:8`).
  - The subject is <= 72 characters (`CONTRIBUTING.md:170`) or <= 50 (`$API/AGENTS.md:52`).
- **Truth (VERIFIED):**
  - Of the 106 merge subjects that name a branch, none uses `fix/` or `feature/`
    (`git -C "$H" log --merges --format=%s | grep -oE 'from [^ ]+'`).
  - Since 2025-01-01, 142 of 293 non-merge subjects exceed 50 characters and 29 exceed 72:
    `git -C "$H" log --no-merges --since=2025-01-01 --format=%s | awk '{n++; if(length>50)a++; if(length>72)b++} END{print n, a, b}'`
    -> `293 142 29` (as of 2026-10-01; `change-control`'s commit-msg check `--since 2025-01-01 --report`
    gives the same three numbers).
  - Measurements: `change-control` → commit/PR conventions.
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** none until the owner decides. Operate under the defaults (<= 72 hard, <= 50
  preferred, `misc` allowed, branch names not enforced) and use the PR template in
  `reference/templates.md`.
- **Class:** C0 once decided. The check prints `OPEN`, not `STALE`.
  <!-- evidence-check: on -->

### SC-37 `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:11` (lago-api)

- **Claim** (`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:11`): "Events-processor writes to a sorted set with ZADD, using the event timestamp as score".
- **Truth (VERIFIED):** Go scores with processing wall-clock time: `now := time.Now().Unix()` and
  `Score: float64(now)` (`events-processor/models/stores.go:55,61`).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** "using the processing time (wall clock, Unix seconds) as score".
- **Class:** a lago-api PR (comment only). The contract itself is owned by `rails-go-parity`.
  <!-- evidence-check: on -->

### SC-38 commit `5308258` message: immutable

- **Claim** (commit `5308258`): lago-deploy kept "the AWS account id out of a public repository".
- **Truth (VERIFIED):** the ECR registry account id is in public workflows
  (`.github/workflows/build-processors-image.yaml:15`, `build-connectors-image.yaml:19`) since
  `2146a18` and `4955f79` (August 2026).
  <!-- evidence-check: off (prescription; the evidence is in Claim/Truth above) -->
- **Corrected text:** none possible (history is immutable, change-control N2). Never repeat the
  claim. Cite this entry instead.
- **Class:** n/a. The check prints `KNOWN`.
  <!-- evidence-check: on -->

## Minor doc defects (verified, not scripted)

- `CONTRIBUTING.md:28` links `#javascript-styleguide`, but the heading is `### Styleguide` (`:175`).
- `CONTRIBUTING.md:113` says "Fill in the template" for enhancements. There is no feature template:
  feature requests go to Canny (`.github/ISSUE_TEMPLATE/config.yml:1-5`).
- `CONTRIBUTING.md:197` describes the `documentation` label as "Feature requests." (copy-paste).
- `CONTRIBUTING.md:209-213` PR-label links point to lago-front pulls.
- `CONTRIBUTING.md:172` `[ci skip]` for docs-only commits is used once in all history (`d01836f`).
  No PR check runs for docs anyway (`events-processor-tests.yml:12-13` path filter).
- `.github/ISSUE_TEMPLATE/bug_report.md:26-29` asks for browser/iOS details and no Lago version or
  deploy method.
- `docs/dev_environment.md:199` has a stray space in the sentinel list (`redis-sentinel-1:26379,
  redis-sentinel-2:26379,...`). Whether lago-api trims it is UNVERIFIED.
- `docs/dev_environment.md:82` installs mkcert with `brew` only (macOS).
- `events-processor/README.md:10` says "With the docker compose environment" over a host build
  command.
