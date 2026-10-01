# Cross-repo contract change protocol (change-control N6; OPEN DECISION OD-4)

Read this before you change anything that lago-api (Rails, ClickHouse migrations, Karafka)
reads or writes together with the events-processor. Such a change is class **C4**.

Set up the pinned reference first. lago-api is read-only reference at the pinned SHA:

```bash
API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)   # api@591ae90 (v1.53.0) as of 2026-10-01
```

The pinned lago-api (`591ae90`, 2026-09-08) is **older** than events-processor HEAD
(`5308258`, 2026-09-18). lago-api `main` may already differ, so every drift claim says "at the
pin `591ae90` (2026-09-08)". Reading it needs network access; see `research-methodology`.

## 1. Contract inventory (who writes, who reads)

All anchors were verified on 2026-10-01. The behaviour of each side is described in
`rails-go-parity` and `architecture-contract`; this table only says who must move together.

| # | Contract | Writer | Reader(s) | Go anchor | lago-api anchor |
|---|---|---|---|---|---|
| K1 | Redis ZSET `subscription_refreshed_v2`: member `<org>:<sub>\|<bucket>`, 10 s bucket, score = Go wall clock | events-processor | lago-api clock job (every 10 s, only if `LAGO_REDIS_STORE_URL` and `LAGO_CLICKHOUSE_ENABLED` are present) | `processors/main_processor.go:152`; `models/stores.go:16,54-69` | `app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:7,14,26-37`; `clock.rb:209-215` |
| K2 | Raw events topic name and payload: `timestamp` = `to_f.to_s`, `ingested_at` = `iso8601(3)[...-1]`, `precise_total_amount_cents` as a string | lago-api; also `connectors/*.yml` | events-processor; ClickHouse `events_raw_queue` | `models/event.go:12-23`; env `LAGO_KAFKA_RAW_EVENTS_TOPIC` (`processors/main_processor.go:36`) | `app/services/events/kafka_producer_service.rb:31,37-53`; `db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:9` |
| K3 | `source_metadata.api_post_processed`: exactly one side post-processes | lago-api | events-processor | `models/event.go:25-27,86-92` | `kafka_producer_service.rb:51` (`!organization.clickhouse_events_store?`) |
| K4 | Enriched topic and payload: the 8 fields ClickHouse reads; `value` is a string | events-processor | ClickHouse `events_enriched_queue` (JSONEachRow) -> `events_enriched.decimal_value Decimal(38,26) DEFAULT toDecimal128OrZero(value, 26)` | `models/event.go:29-48`; `processors/events_processor/enrichment_service.go:111-116`; key `<org>-<transaction_id>` at `event_producer_service.go:30,41` | `db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:9-22`; `20240705080709_create_events_enriched.rb:32` |
| K5 | Charged-in-advance topic and payload | events-processor | lago-api Karafka `EventsChargedInAdvanceConsumer` | same struct as K4 | `karafka.rb:49-55` |
| K6 | Dead-letter topic and payload | events-processor | ClickHouse `events_dead_letter_queue` | `models/event.go:50-56` | `db/clickhouse_migrate/20251110130723_create_events_dead_letter_queue.rb:9-19` |
| K7 | events-processor consumer group `<LAGO_KAFKA_CONSUMER_GROUP>_<topic>`; a new group starts at the **earliest** offset | ops / env | Kafka | `config/kafka/consumer.go:237` (franz-go v1.20.5 default reset `AtStart`, `pkg/kgo/config.go:578`) | n/a (ClickHouse uses `LAGO_KAFKA_CLICKHOUSE_CONSUMER_GROUP`) |
| K8 | Rails table columns that Go selects explicitly | lago-api migrations | events-processor | `models/subscriptions.go:24,37` (`schema.Parse`, `Select`); `SelectFields` in `models/{billable_metrics,charges,charge_filters,charge_filter_values,billable_metric_filters}.go` | `$API/docs/dropping_columns_and_tables.md` (two-release drop) |
| K9 | Debezium CDC column list (memory-cache mode only, OPEN DECISION OD-1 (owner)) | Postgres via Debezium, configured outside this repo | events-processor cache | `cache/*.go` topic suffixes `.public.<table>`; `main.go:24` | `extra/debezium_config.json:2,47` (reference config in this repo) |
| K10 | Reusable image-build workflow interface (unpinned caller: OPEN DECISION OD-14 (owner)) | this repo | lago-front release at `@main` | `.github/workflows/docker-build-multi-arch.yaml` inputs | `$FRONT/.github/workflows/release.yml:13` (`FRONT=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh front)`) |

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
  (`$API/AGENTS.md:176-177`). Schema changes are OPEN DECISION OD-3 (owner).
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
4. **Open the paired lago-api PR** (OD-4 default: mandatory) and link the two PRs both ways.
   - Each side pins the format in a test: the Go test asserts the exact key, member or JSON;
     the lago-api spec asserts what it reads (spec conventions in `$API/AGENTS.md:206-243`).
5. **Get sign-off.** The events-processor maintainer, the lago-api owner of the reader or writer,
   and the owner for any delivery-semantics part (N7, OD-2). Review routing is in SKILL.md.
   If the PR changes no K-row, write "N6: not applicable because <reason>" instead of steps 2-6.
6. **Deploy in this order: tolerant reader, then writer, then cleanup** (expand, migrate,
   contract).

   | Contract direction | Ships first | Ships second | Cleanup (later release) |
   |---|---|---|---|
   | Go writes, Rails/ClickHouse reads (K1, K4, K5, K6) | lago-api: reads old **and** new (dual-read), or a ClickHouse migration that accepts the new field | events-processor: switches the writer | lago-api: drops the old read path once the old key or topic is drained |
   | Rails writes, Go reads (K2, K3) | events-processor: accepts old **and** new | lago-api: emits the new format | events-processor: drops the old parse path |
   | Rails schema, Go reads columns (K8) | events-processor: stops selecting the column (release N) | lago-api: `ignored_columns`, then the drop migration (release N+1, per `$API/docs/dropping_columns_and_tables.md`) | n/a |
   | Topic or group rename (K2, K4, K6, K7) | lago-api ClickHouse migration for the new queue table, and the topic created | events-processor env switch (new group = replay from earliest; plan for duplicates) | delete the old topic and queue table after retention |

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
  shared or production cluster that is an owner call (OD-2) and C4. There is no DLQ replay tool:
  a manual re-feed from the DLQ is CANDIDATE and needs OPEN DECISION OD-2 (owner).

## 4. Smells that mean "stop, this is C4"

- A constant that also exists in `$API` changes: a bucket, a key, a topic, an enum value.
  Example: `SUBSCRIPTION_BUCKET_DURATION` must equal Rails `SUBSCRIPTION_BUCKET_DURATION = 10`.
- A JSON tag in `models/event.go` changes, or a field type changes. Example:
  `precise_total_amount_cents` is a `string` in Go (`models/event.go:18`), while
  `connectors/http.yml:32-36` passes a JSON number through (Go then fails to unmarshal it:
  committed, Sentry only) and maps any non-number to `"0"`. No value-preserving workaround
  exists through the connectors; the fix is campaign W2 (`event-accounting-campaign`).
- The `value` string formatting changes (`enrichment_service.go:114`). ClickHouse parses it with
  `toDecimal128OrZero`. That is C3 + C4 (K4): paired lago-api PR (OD-4); a ClickHouse schema
  change only via OD-3; campaign work in `event-accounting-campaign`.
- Rails-side flags that change which side does the work: `pre_filter_events`,
  `lazy_charge_usage_cache`, `enriched_events_aggregation`. Their production state is OPEN
  DECISION OD-8 (owner). State "impact depends on OD-8".
