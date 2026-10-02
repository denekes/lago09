# Cross-repo contract change protocol (change-control N6; DECIDED OD-4)

Read this before you change anything that lago-api (Rails, ClickHouse migrations, Karafka),
lago-front, a deployment repo or the connectors read or write together with the
events-processor. Such a change is class **C4**.

**DECIDED OD-4 (owner, 2026-10-02): the paired PR is dependency-driven.** A contract change
needs a paired PR in every OTHER repo that reads or writes the part that changes. If no other
repo does, no paired PR: say so in the PR, citing the row's "External dependents" cell (§1).
Deploy order and rollback rules (§2-§3) still apply whenever a dependent exists.

Set up the pinned reference first. lago-api is read-only reference at the pinned SHA:

```bash
API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)   # api@591ae90 (v1.53.0) as of 2026-10-01
```

The pinned lago-api (`591ae90`, 2026-09-08) is **older** than events-processor HEAD
(`5308258`, 2026-09-18). lago-api `main` may already differ, so every drift claim says "at the
pin `591ae90` (2026-09-08)". Reading it needs network access; see `research-methodology`.

## 1. Contract inventory (who writes, who reads)

The anchors were verified on 2026-10-01, the external-dependents column on 2026-10-02. The behaviour of each side is described in
`rails-go-parity` and `architecture-contract`; this table only says who must move together.
The `rails-go-parity` P rows carry these K-IDs (its SKILL.md §2 "Contract (change-control K#)"
column; `rails-go-parity` `reference/contract-table.md` has the K -> P index).

| # | Contract | Writer | Reader(s) | Go anchor | lago-api anchor | External dependents (repo: file; verified 2026-10-02) |
|---|---|---|---|---|---|---|
| K1 | Redis ZSET `subscription_refreshed_v2`: member `<org>:<sub>\|<bucket>`, 10 s bucket, score = Go wall clock | events-processor | lago-api clock job (every 10 s, only if `LAGO_REDIS_STORE_URL` and `LAGO_CLICKHOUSE_ENABLED` are present) | `processors/main_processor.go:152`; `models/stores.go:16,54-69` | `app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:7,14,26-37`; `clock.rb:209-215` | lago-api: `app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:7,14` (name, 10 s bucket), `clock.rb:209-215` (the 10 s job). lago-helm-charts: none (passes only `LAGO_REDIS_STORE_URL`, `charts/lago/templates/events-processor-worker-deployment.yaml:63`). Name, member, bucket or score change: paired lago-api PR |
| K2 | Raw events topic name and payload: `timestamp` = `to_f.to_s`, `ingested_at` = `iso8601(3)[...-1]`, `precise_total_amount_cents` as a string | lago-api; also `connectors/*.yml` | events-processor; ClickHouse `events_raw_queue` | `models/event.go:12-23`; env `LAGO_KAFKA_RAW_EVENTS_TOPIC` (`processors/main_processor.go:36`) | `app/services/events/kafka_producer_service.rb:31,37-53`; `db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:9` | lago-api writers: `app/services/events/kafka_producer_service.rb:31,36-54`; `app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb:63-91` (a second writer: `timestamp` as `strftime("%s.%3N")`, adds `source_metadata.reprocess`). lago-api readers: `db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:9-23`, `20231030163703_create_events_raw_mv.rb:6-16`. This repo, other deployables: `connectors/{http,kinesis,sqs}.yml` (writers). lago-helm-charts: topic `charts/lago/values.yaml:116`, created by `charts/lago/templates/create-topic-job.yaml:30`. Cloud ingestion: UNVERIFIED (no Kafka engine in `$API/db/clickhouse_migrate/cloud/`) |
| K3 | `source_metadata.api_post_processed`: exactly one side post-processes | lago-api | events-processor | `models/event.go:25-27,86-92` | `kafka_producer_service.rb:51` (`!organization.clickhouse_events_store?`) | lago-api writers only: `kafka_producer_service.rb:49-51`, `re_enrich_subscription_events_service.rb:87-90` (always `true`). No reader outside the events-processor. Connectors set no `source`, so Go treats their events as not post-processed (`events-processor/models/event.go:86-92`) |
| K4 | Enriched topic and payload: the 8 fields ClickHouse reads; `value` is a string | events-processor | ClickHouse `events_enriched_queue` (JSONEachRow) -> `events_enriched.decimal_value Decimal(38,26) DEFAULT toDecimal128OrZero(value, 26)` | `models/event.go:29-48`; `processors/events_processor/enrichment_service.go:111-116`; key `<org>-<transaction_id>` at `event_producer_service.go:30,41` | `db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:9-22`; `20240705080709_create_events_enriched.rb:32` | lago-api: `db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:9-22`, `20240705085501_create_events_enriched_mv.rb:5-16`, `20240705080709_create_events_enriched.rb:32` (`decimal_value`); Cloud `db/clickhouse_migrate/cloud/02_events_enriched.sql:12` (`Nullable(Decimal(38, 26))`); Rails reads `events_enriched` (e.g. `app/services/events/stores/clickhouse_store.rb`, the `FINAL` gate `app/services/billable_metrics/aggregations/base_service.rb:168`). lago-helm-charts: `charts/lago/values.yaml:114` + the create-topic job |
| K5 | Charged-in-advance topic and payload | events-processor | lago-api Karafka `EventsChargedInAdvanceConsumer` | same struct as K4 | `karafka.rb:49-55` | lago-api: `karafka.rb:49-55` (Karafka DLQ topic `unprocessed_events`), `app/consumers/events_charged_in_advance_consumer.rb:3-8` -> `Events::PayInAdvanceJob` -> `app/services/events/pay_in_advance_service.rb:15,55` (`already_processed?`). lago-helm-charts: `charts/lago/values.yaml:112` + the create-topic job |
| K6 | Dead-letter topic and payload | events-processor | ClickHouse `events_dead_letter_queue` | `models/event.go:50-56` | `db/clickhouse_migrate/20251110130723_create_events_dead_letter_queue.rb:9-19` | lago-api: `db/clickhouse_migrate/20251110130723_create_events_dead_letter_queue.rb:9-19`, the MV as last changed by `20260430075848_update_events_dead_letter_mv.rb:7-26` (`JSONExtractString(event, …)`), `app/models/clickhouse/events_dead_letter.rb` (`event :json`); Cloud `db/clickhouse_migrate/cloud/07_events_dead_letter_queue.sql:4` (`event JSON`). lago-helm-charts: `charts/lago/values.yaml:113` + the create-topic job. A new `error_code` value is additive (string column, `20251110130723_create_events_dead_letter_queue.rb:17`); a non-JSON `event` (e.g. ADR-001 raw bytes) does not fit these readers (INFERRED from the DDL): add a field + paired lago-api PR |
| K7 | events-processor consumer group `<LAGO_KAFKA_CONSUMER_GROUP>_<topic>`; a new group starts at the **earliest** offset | ops / env | Kafka | `config/kafka/consumer.go:237` (franz-go v1.20.5 default reset `AtStart`, `pkg/kgo/config.go:578`) | n/a (ClickHouse uses `LAGO_KAFKA_CLICKHOUSE_CONSUMER_GROUP`) | none known in lago-api code (ClickHouse uses `LAGO_KAFKA_CLICKHOUSE_CONSUMER_GROUP`, `db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:10`). Env only: lago-helm-charts `charts/lago/templates/_helpers.tpl:30-31` (default `events_consumer`, `charts/lago/values.yaml:107`); this repo `.env.development.default:90`. Lag dashboards or alerts keyed on group names: UNVERIFIED |
| K8 | Rails table columns that Go selects explicitly | lago-api migrations | events-processor | `models/subscriptions.go:24,37` (`schema.Parse`, `Select`); `SelectFields` in `models/{billable_metrics,charges,charge_filters,charge_filter_values,billable_metric_filters}.go` | `$API/docs/dropping_columns_and_tables.md` (two-release drop) | lago-api: the owning migrations and `db/structure.sql` (`billable_metric_filters` :2324, `billable_metrics` :2340, `charge_filter_values` :2548, `charge_filters` :2564, `charges` :2581, `subscriptions` :3901); drop rule `docs/dropping_columns_and_tables.md`. Go selecting an existing column needs no paired PR, but binds future drops |
| K9 | Debezium CDC column list (memory-cache mode, which production runs: DECIDED OD-1 (owner, 2026-10-02); the production list is OPEN DECISION OD-1b (owner)) | Postgres via Debezium, configured outside this repo | events-processor cache | `cache/*.go` topic suffixes `.public.<table>`; `main.go:24` | `extra/debezium_config.json:2,47` (reference config in this repo) | production Debezium connector config: outside every repo visible here (OPEN DECISION OD-1b (owner)). This repo: `extra/debezium_config.json:2,41,47` (reference config). lago-api: the listed columns must exist (`db/structure.sql`, as K8). lago-helm-charts: none (no Debezium or `MEMORY_CACHE` reference at `d473b1e`) |
| K10 | Reusable image-build workflow interface (unpinned caller: OPEN DECISION OD-14 (owner)) | this repo | lago-front release at `@main` | `.github/workflows/docker-build-multi-arch.yaml` inputs | `$FRONT/.github/workflows/release.yml:13` (`FRONT=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh front)`) | lago-front: `.github/workflows/release.yml:13` (`@main`). lago-api: none at the pin. This repo callers: `.github/workflows/release-images.yml:10,22,34`, `build-connectors-image.yaml:17`, `build-processors-image.yaml:13` |

How to read the dependents column (decides the paired PRs, DECIDED OD-4):

- Paths after "lago-api:" are relative to `$API` (the pin `591ae90`), after "lago-front:" to
  `$FRONT`. Paths after "lago-helm-charts:" are relative to a depth-1 clone of the public chart
  (`git clone --depth 1 https://github.com/getlago/lago-helm-charts`, `d473b1e`, 2026-08-18; a
  proxy for Helm self-hosters, not Cloud).
- The private lago-deploy (production) is not visible from here: its dependence on any row is
  UNVERIFIED. Ask the owner when a change renames or adds a topic, group or env var.
- A paired PR is needed only in a repo whose listed file reads or writes the part that changes
  (DECIDED OD-4). "none" means none known after the greps in SKILL.md Provenance.

Facts that shape the protocol:

- **Topic names are baked in.** ClickHouse queue tables are created with the topic name from env
  at migrate time (K2, K4, K6). Renaming a topic needs a ClickHouse migration in lago-api.
- **Group names replay.** Renaming the topic or `LAGO_KAFKA_CONSUMER_GROUP` makes a new group,
  which replays the whole retained raw topic (K7).
- **Replays duplicate.** Duplicates in `events_enriched` collapse only at merge time
  (`ReplacingMergeTree(timestamp)`, `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:6`),
  or at query time with `FINAL`, which lago-api uses only for orgs with
  `clickhouse_deduplication_enabled` (default false, `$API/app/models/organization.rb:348`;
  gate at `$API/app/services/billable_metrics/aggregations/base_service.rb:168`).
- **Extra fields are tolerated; the read fields are not.** The enriched queue reads only 8
  fields. The events-processor already sends more, and production ingests it (`d9c32b6` body:
  the queue "never read the charge columns"). Removing, renaming or retyping one of the 8 fields
  breaks ingestion.
- **ClickHouse DDL is not transactional.** Cloud DDL is edited in place
  (`$API/AGENTS.md:176-177`). Schema changes are allowed (DECIDED OD-3 (owner, 2026-10-02)); the
  self-host migration and the Cloud DDL both live in lago-api, so they ship as a paired lago-api
  PR with a deploy order.
- **Deployment repos create topics and set env.** The public Helm chart creates every topic
  listed in `global.clickhouse.kafka.topics` (`charts/lago/templates/create-topic-job.yaml:30`,
  `charts/lago/values.yaml:111-118`) and sets the Kafka env of its Kafka pods
  (`charts/lago/templates/_helpers.tpl:25-58`, included by the events-processor, api,
  events-consumer and migrate templates). A new topic, such as the ADR-001 retry topic, or a new
  Kafka env var needs: the dev topic list (`docker-compose.dev.yml:398-405`, C4 + C6), a paired
  lago-helm-charts PR, and production provisioning (owner/ops). The retry topic itself has no
  reader outside the events-processor, so it needs no paired lago-api PR.
- **The root compose does not run the events-processor.** `docker-compose.yml` services are
  `db migrate pdf redis api api-clock api-worker front`. Production deploy order for the
  events-processor is run from the private `lago-deploy`. That pipeline is UNVERIFIED from here.

## 2. The protocol (C4)

1. **Name the contract and the direction.** Use a row of §1. Decide which side writes and which
   reads. If no row fits, add one in the PR and tell `rails-go-parity`.
2. **Prefer additive.** Add a field or an optional behaviour that old readers ignore. If the
   meaning or format of an existing name changes, **use a new versioned name** (`_v3` key, new
   topic, new field). Precedent: `42615c9` changed SET to ZSET **and** renamed
   `subscription_refreshed` to `subscription_refreshed_v2`, so no reader ever met the wrong type.
3. **Write the design note in the PR** (ADR template in `docs-and-writing`). It must state:
   - the contract before and after;
   - the direction;
   - the mixed-version behaviour in both windows (old writer + new reader, new writer + old
     reader);
   - the deploy order;
   - the rollback;
   - the cleanup step and who owns it.
4. **Open the paired PRs the dependents need** (DECIDED OD-4). For each repo in the row's
   "External dependents" cell whose file reads or writes the changed part, open a paired PR and
   link the PRs both ways. If none is touched, write "N6: no external dependent of <K#> is
   touched" and cite the cell.
   - Each side pins the format in a test: the Go test asserts the exact key, member or JSON;
     the lago-api spec asserts what it reads (spec conventions in `$API/AGENTS.md:206-243`).
5. **Get sign-off.** The events-processor maintainer, the owner of each paired PR's repo, and
   the owner for any delivery-semantics part (N7). A delivery part must conform to ADR-001
   (DECIDED OD-2); a deviation needs an owner decision first. Review routing is in SKILL.md.
   If the PR changes no K-row, write "N6: not applicable because <reason>" instead of steps 2-6.
6. **Deploy in this order: tolerant reader, then writer, then cleanup** (expand, migrate,
   contract).

   | Contract direction | Ships first | Ships second | Cleanup (later release) |
   |---|---|---|---|
   | Go writes, Rails/ClickHouse reads (K1, K4, K5, K6) | lago-api: reads old **and** new (dual-read), or a ClickHouse migration that accepts the new field | events-processor: switches the writer | lago-api: drops the old read path once the old key or topic is drained |
   | Rails writes, Go reads (K2, K3) | events-processor: accepts old **and** new | lago-api: emits the new format | events-processor: drops the old parse path |
   | Rails schema, Go reads columns (K8) | events-processor: stops selecting the column (release N) | lago-api: `ignored_columns`, then the drop migration (release N+1, per `$API/docs/dropping_columns_and_tables.md`) | n/a |
   | Topic or group rename (K2, K4, K6, K7) | lago-api ClickHouse migration for the new queue table (K2, K4, K6; the name is baked in at `$API/db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:9`), and the topic created (dev list, lago-helm-charts PR, production ops) | events-processor env switch (new group = replay from earliest; plan for duplicates) | delete the old topic and queue table after retention |
   | New internal topic (e.g. the ADR-001 retry topic; no reader outside the events-processor) | the topic created in every environment: dev topic list (`docker-compose.dev.yml:398-405`, C6), lago-helm-charts PR (`charts/lago/templates/create-topic-job.yaml:30`), production provisioning (owner/ops) | events-processor starts producing to it | n/a (deleting it later is irreversible: cleanup rules apply) |

7. **Verify after each step.** For example: `ZCARD subscription_refreshed_v2` drains to near zero
   every 10 s, consumer lag is flat, and the DLQ rate is flat. These need a running stack and
   are not runnable in a daemon-less sandbox; the 10 s cadence was verified by reading
   `$API/clock.rb:209-215`. How to observe them is in `run-and-operate`. The
   events-processor has no metrics endpoint, so lag comes from Kafka tooling.
8. **Update the docs.** The contract table in `rails-go-parity`, the topology in
   `architecture-contract`, and env names in `config-and-flags`.

## 3. Rollback rules

- **Before the writer switches.** Reverting the reader is harmless.
- **After the writer switches.** Roll back the **writer first** (it writes the old name or format
  again). The reader still accepts both. Then investigate.
- **Never roll back a reader below the format its writer emits.** That is why the cleanup step
  waits at least one release.
- **Irreversible steps only in cleanup:** column drops, topic deletion, ClickHouse DDL. Do them
  only after a full release cycle on the new path.
- **The events-processor commits offsets.** A writer rollback does not re-emit records that
  were already committed. If a bad format reached a topic, plan a raw-topic replay: a new
  consumer group from a timestamp offset (ops; `run-and-operate`) and accept duplicates. On a
  shared or production cluster that is an owner call and C4. There is no DLQ replay tool yet:
  ADR-001 (DECIDED OD-2) specifies an operator-gated DLQ -> raw-topic replay with a replay
  header, safe only once downstream idempotency is in place; until it is built, a manual re-feed
  is CANDIDATE and an owner call.

## 4. Smells that mean "stop, this is C4"

- A constant that also exists in `$API` changes: a bucket, a key, a topic, an enum value.
  Example: `SUBSCRIPTION_BUCKET_DURATION` must equal Rails `SUBSCRIPTION_BUCKET_DURATION = 10`.
- A JSON tag in `models/event.go` changes, or a field type changes. Example:
  `precise_total_amount_cents` is a `string` in Go (`models/event.go:18`), while
  `connectors/http.yml:32-36` passes a JSON number through (Go then fails to unmarshal it:
  committed, Sentry only) and maps any non-number to `"0"`. No value-preserving workaround
  exists through the connectors; the fix is campaign W2 (`event-accounting-campaign`).
- The `value` string formatting changes (`enrichment_service.go:114`). ClickHouse parses it with
  `toDecimal128OrZero`. That is C3 + C4 (K4, which has lago-api dependents): paired lago-api PR
  (DECIDED OD-4); a ClickHouse schema change is allowed and rides in that PR (DECIDED OD-3);
  campaign work in `event-accounting-campaign`.
- Rails-side flags that change which side does the work: `pre_filter_events`,
  `lazy_charge_usage_cache`, `enriched_events_aggregation`. Their production state is
  OPEN DECISION OD-8 (owner). State "impact depends on OD-8".
