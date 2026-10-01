# events-processor ledger: every non-dependabot commit, classified

Read this when you need the full chronicle behind a chain, or when a commit sha shows up in a blame
and you want to know whether it was a fix, a regression, or a removal. The narrated chains are in
`chains.md`; this file is the row-per-commit record.

Scope: all 79 non-dependabot commits under `events-processor/` and its pre-rename name
`events_processor/` (renamed in `d5bce86`, 2025-03-21). Re-list them with
`.claude/skills/failure-archaeology/scripts/hist.sh --ep --humans --reverse` (expect 79 lines; 96 with
dependabot). Facts verified 2026-10-01 against the history clone (code facts as of `5308258`); "inferred" marks a root cause read
from code shape or a subject line when the commit has no body.

Kinds: FIX, HOTFIX, REGRESSION (a commit that introduced a defect fixed later), REMOVAL, FEAT,
REFACTOR, CHORE, DOCS, TEST. Status: settled / superseded / removed / residual / open (see SKILL.md Terms).
Chain letters refer to `chains.md`.

| Date | Sha | PR | Kind | Symptom | Root cause | Fix / change | Status | Chain |
|---|---|---|---|---|---|---|---|---|
| 2025-03-11 | `4100da0` | #474 | FEAT | (new service) | n/a | Go post-processor: franz-go consumer, enrich, in-advance and DLQ producers; dir `events_processor/`, module `…/events-processors` | superseded by later refactors | origin of A B C E I J L N |
| 2025-03-13 | `e58befb` | #484 | FIX | startup errors missing from Sentry | `os.Exit(1)` skips the Sentry flush | `panic` + capture | settled (now `utils.LogAndPanic`) | – |
| 2025-03-13 | `4ce963e` | #485 | FIX | Sentry environment empty | read `ENVIRONMENT`, deployments set `ENV` | use `ENV` | settled | – |
| 2025-03-14 | `07d1d4d` | #487 | FIX | expression tests broke on a float timestamp | lago-expression cloned at HEAD (unpinned) | pin `v0.1.4` in Dockerfiles and CI; dev Rust 1.85 | superseded by `5077151` | L |
| 2025-03-14 | `baba284` | #488 | FEAT | DLQ rows lack a failure time | n/a | `failed_at` | settled | – |
| 2025-03-20 | `1a9fcf6` | #492 | FEAT | one DB connection | n/a | pgxpool (max 200); debugger wiring removed | settled | – |
| 2025-03-20 | `eb21b28` | #493 | FIX | module path `events-processors` vs dir; image rebuilt on every push | naming; no `paths:` filter | rename module; workflow `paths:` filter | settled | – |
| 2025-03-21 | `d5bce86` | #494 | REFACTOR | dir name ≠ module name | n/a | `events_processor/` → `events-processor/` (workflows updated in the same commit) | settled; history needs the rename-aware pathspec | – |
| 2025-03-21 | `f277b44` | #495 | FEAT | pool size not tunable | n/a | env `…_MAX_CONNEXIONS` (typo); a parse error set the size to 0 | superseded: renamed silently in `7421650` | M |
| 2025-03-21 | `d1c1629` | #496 | FIX | in-advance double handling with API-post-processed events | only `source` was checked | `source_metadata.api_post_processed` gate | settled (gate at `processors/events_processor/processor.go:115`); also moved api/front pins | E X6 |
| 2025-03-21 | `c19a881` | #497 | FIX | Sentry noise | not-found errors captured | capture flag | superseded by `cec0eb2` | – |
| 2025-03-24 | `4ce67cf` | #498 | FEAT | Sentry events lack the event | n/a | attach event as extra | settled | – |
| 2025-03-31 | `cec0eb2` | #502 | REGRESSION | transient errors went straight to the DLQ | no retry semantics | `Retryable`/`Capture`, 12 h window, `findMaxCommitableRecord`; introduced the stray `return` in `consume()` | bug fixed in steps (`600e195`, `b6d3616`, `9acd83e`); retry semantics residual (OD-2) | A I |
| 2025-04-07 | `7421650` | #500 | FEAT | Rails cannot tell which subscriptions need a refresh | n/a | Redis `SADD subscription_refreshed`; Redis mandatory; typo `LLAGO_REDIS_STORE_PASSWORD`; `CONNEXIONS`→`CONNECTIONS`; moved api/front pins | superseded by `42615c9`; typo fixed `69ec50d` | G M X6 |
| 2025-04-07 | `69ec50d` | #505 | FIX | Redis (Valkey) connection failed | password env typo; no timeouts, no TLS | env fixed, timeouts, TLS when `ENV=production` (`InsecureSkipVerify`) | settled; TLS reworked `a918f60` | G H M |
| 2025-04-10 | `656c829` | #511 | FIX | produce/commit failures silent; poison records hit the stray `return` | errors not captured; unparseable records never "processed" | capture errors; commit unparseable records | residual: unparseable records get no DLQ (`processor.go:49-59`) | A |
| 2025-04-10 | `dd75456` | #512 | FIX | events dropped when the subscription is missing | not-found aborted enrichment | keep enriching without subscription | settled | – |
| 2025-04-11 | `d7d76be` | #513 | FIX | unmarshal failure on `ingested_at` | unix-timestamp string not accepted | fall back to `ToTime` | settled | I |
| 2025-06-09 | `3a6ed00` | #542 | FEAT | stale usage cache for ClickHouse orgs | Rails could not expire cache for Kafka-path events | flat_filters view, `MatchingFilter`, Redis `DEL` of Rails keys; `LAGO_REDIS_CACHE_DB=0` in dev env | removed (`2fd8e8b`, `d9c32b6`) | D F H |
| 2025-06-10 | `8d61fa7` | #544 | FIX | cache Redis connection failed in prod | TLS forced for the cache store | `UseTLS:false` | removed with the cache | F H |
| 2025-07-21 | `2477b8e` | #555 | FEAT | – | n/a | enrich `aggregation_type` | settled | – |
| 2025-08-05 | `4f5dcc9` | #556 | FEAT | – | n/a | enrich `subscription_id`, `plan_id` | settled | – |
| 2025-08-07 | `60069c9` | #561 | REFACTOR | – | n/a | `EventEnrichmentService` | settled | – |
| 2025-08-11 | `f1d369a` | #563 | FEAT | – | n/a | per-charge fan-out with charge and filter ids | removed `d9c32b6` | D |
| 2025-08-11 | `26e7c7c` | #564 | FEAT | – | n/a | `grouped_by` from `pricing_group_keys` (built with `%v`) | removed `d9c32b6` | D N |
| 2025-08-11 | `5fd937a` | #566 | REFACTOR | – | n/a | `EventProducerService` | settled | – |
| 2025-08-14 | `d7ee4c2` | #569 | FEAT | – | n/a | pay-in-advance from flat filters; `models/charges.go` deleted | superseded by `d9c32b6` | D E |
| 2025-08-14 | `fa5b45f` | #570 | REFACTOR | – | n/a | `SubscriptionRefreshService` | settled | G |
| 2025-08-25 | `3dae52f` | #567 | FEAT | – | n/a | `events_enriched_expanded` producer, topic env mandatory (panic if unset); `count` value `"1"` | removed `d9c32b6` (`"1"` kept) | D M N |
| 2025-08-25 | `36b1e23` | #574 | FIX | nil-pointer panic | `ev.FlatFilter` nil when no charge matched | nil guard | removed with flat filters | D E |
| 2025-08-26 | `0c46c8a` | #575 | FIX | `grouped_by` nil or wrong | nil map; one map shared by every fan-out copy | init per copy | removed with flat filters | D |
| 2025-09-10 | `d589940` | #586 | FIX | dev container build failed | `air@latest` requires Go 1.25 | pin `air`, `dlv` | settled | L |
| 2025-09-15 | `222691f` | #589 | FIX | OTel required in production | gated on `ENV=production` | gate on endpoint | superseded `475761d` | K |
| 2025-09-16 | `9a64eb2` | #593 | REFACTOR | env names scattered | n/a | central constants | settled | – |
| 2025-09-19 | `264beb5` | #590 | DOCS | README gaps | n/a | env table | stale again (lists removed `LAGO_REDIS_CACHE_URL`) | M |
| 2025-10-14 | `45b216d` | #603 | TEST | flaky `TestEnrichEvent` | map iteration order in the fan-out | sort before asserting | removed with flat filters | D |
| 2025-10-17 | `4cd30f2` | #610 | FIX | usage cache refilled with pre-ClickHouse data | `DEL` ran before ClickHouse ingestion | `EXPIRE 5s` | removed `2fd8e8b` | F |
| 2025-10-28 | `09a5cc7` | #612 | FEAT | only one broker accepted | `SeedBrokers(single)` | comma-separated list; moved api/front pins | settled; residual in CDC consumers (`cache/consumer.go:28-31`) | X6 |
| 2025-10-29 | `a918f60` | #613 | FEAT | TLS tied to `ENV` | n/a | `LAGO_REDIS_STORE_TLS`, `LAGO_REDIS_CACHE_TLS`, legacy fallback | settled; residual `InsecureSkipVerify` | H |
| 2025-11-03 | `2408a73` | #606 | REFACTOR | – | n/a | `processors/events_processor/`, `main_processor.go` (`processors/events.go` moved) | settled | – |
| 2025-11-04 | `fc70e75` | #622 | CHORE | dev start races; no graceful stop | bare `depends_on`; air kill | conditions; air `send_interrupt` | settled | X4 |
| 2025-11-06 | `a15bd3b` | #624 | FIX | offsets could be committed before produce finished | fire-and-forget `go Produce…` | errgroup, produce awaited | settled | J |
| 2025-11-07 | `b0209f6` | #626 | REFACTOR | – | n/a | app setup moved to `main` | settled | – |
| 2025-11-07 | `600e195` | #628 | REGRESSION | – | refactor | `processRecordsAndCommit` extracted (`return` now skips the commit); `poll()` now loops forever on client close | fixed by `b604769`, `b6d3616` | A |
| 2025-11-10 | `b604769` | #629 | HOTFIX | infinite poll loop | introduced 3 days earlier by `600e195` | `pollRecords` returns bool | settled | A |
| 2025-11-17 | `b38bbfd` | #632 | CHORE | – | n/a | dependency update | n/a | – |
| 2025-11-17 | `75b9cbc` | #600 | FEAT | – | n/a | pre-aggregation enabled for every event with a charge; moved api/front pins | removed `d9c32b6` | D X6 |
| 2025-11-18 | `bd92069` | #634 | REGRESSION | DB load | join on `customers` | filter on `subscriptions.organization_id`; gorm now emits `SELECT *` | root of SQLSTATE 0A000, fixed `9acd83e` | B |
| 2025-11-25 | `b6d3616` | #608 | REGRESSION | no graceful shutdown | n/a | signals, cancelable root ctx, per-partition quit; removed the `return` (→ nil commit record); stores' captured ctx now canceled on SIGTERM | fixed by `9acd83e`, `02a4bc8` | A J |
| 2025-11-27 | `3fc0d7e` | #644 | REFACTOR | – | n/a | `LogAndPanic` | settled | – |
| 2025-11-27 | `27169be` | #642 | FIX | `LAGO_KAFKA_TLS=1` ignored | `== "true"` | `GetEnvAsBool` | settled; residual: default on unparsable (`utils/env.go:35-43`) | M |
| 2025-11-27 | `475761d` | #633 | FEAT | tracing vendor lock-in | n/a | provider abstraction on dd-trace-go v1 (go.mod +235/−8 lines incl. confluent/sarama/segmentio indirect deps) | superseded next day | K |
| 2025-11-28 | `a9c9eb5` | #646 | REFACTOR | – | n/a | Kafka loggers through the provider; `TODO(datadog)` | settled | K |
| 2025-11-28 | `1f2d36e` | #641 | FEAT | no Kafka spans in Datadog | n/a | dd-trace-go v2 + Kafka hooks; v1 indirect Kafka clients dropped | settled | K |
| 2026-01-02 | `5077151` | #666 | FEAT | new expression functions needed | Rust lib at v0.1.4 | lago-expression `v0.2.0` in 3 files (Go wrapper stays `v0.1.4`) | settled (do not "fix" go.mod, change-control N3) | L |
| 2026-01-02 | `e8bbd60` | #667 | FIX | prod image build failed | `Dockerfile` still `rust:1.82` (exact requirement inferred) | `rust:1.85` | settled | L |
| 2026-01-08 | `d4e3665` | none | FIX | build did not pick up the new tag (inferred) | cached `git clone` layer (inferred, UNVERIFIED) | `git clone --tags` | settled | L |
| 2026-02-19 | `2cf3864` | #701 | FEAT | – | n/a | `target_wallet_code` enrichment | removed `d9c32b6` (Rails TODO remains, see SKILL.md stalled list) | D |
| 2026-03-03 | `2fec4db` | #710 | FIX | `grouped_by` empty for the default bucket; `"<nil>"` values | `ToDefaultFilter` dropped keys; `%v` of nil | copy keys; `""` for nil (grouped_by only) | removed; the `%v` class remains for `value` | D N |
| 2026-03-05 | `76c1b3b` | #709 | FIX | ISO timestamps → DLQ (non-retryable) | only numeric timestamps parsed | RFC3339 fallback | settled; residual UTC/ms gap (`utils/time.go:25-29`) | I |
| 2026-03-05 | `c340ddf` | #711 | CHORE | noisy or missing logs | n/a | slog, DEBUG in development; added `events-processor/CLAUDE.md` | settled (CLAUDE.md stale, see `docs-and-writing`) | – |
| 2026-03-06 | `6048999` | #712 | FEAT | – | n/a | `source_metadata.reprocess` → expanded events only | removed `d9c32b6` (Rails still sends `reprocess`) | D |
| 2026-03-27 | `42615c9` | #720 | FIX | refresh ran before data landed (inferred from `CLICKHOUSE_MERGE_DELAY`) | `SADD` set drained immediately | `ZADD subscription_refreshed_v2`, 15 s bucket; cache `EXPIRE 15s` | settled (tuned `fb6401d`) | F G |
| 2026-04-09 | `50015b0` | #725 | CHORE | go.mod already said `go 1.25.0` | dependabot `932c06c` (#724) raised it 50 min earlier | CI + Dockerfiles to Go 1.25 | settled | L |
| 2026-04-20 | `fb6401d` | #729 | CHORE | refresh latency | 15 s too long | 10 s bucket and expiry (`SUBSCRIPTION_BUCKET_DURATION`) | settled (Rails = 10) | F G |
| 2026-04-27 | `fff5858` | #639 | REGRESSION | DB load from per-event lookups | n/a | Badger cache + Debezium CDC behind `LAGO_USE_MEMORY_CACHE`; `gorm.DeletedAt`→`utils.NullTime` (soft-delete scope lost); 101 BM test lines deleted; moved api/front pins | flag-gated, OD-1 (CDC hardening unowned: OD-20); soft-delete fixed `8ceca4b` | C X6 |
| 2026-04-27 | `2d2ba86` | #691 | CHORE | old base image | n/a | `debian:13-slim` | settled | – |
| 2026-04-27 | `731e18f` | #733 | FIX | produce failures (title: "producer keys limits") | expanded-topic key embedded the grouped_by string (inferred) | every key = `<org>-<transaction_id>` | settled; per-subscription ordering no longer guaranteed (impact UNVERIFIED) | D |
| 2026-05-06 | `9acd83e` | #735 | FIX | pod segfault inside franz-go; SQLSTATE 0A000 after Rails migrations | nil record passed to `CommitRecords`; `SELECT *` plan invalidated by DDL | `(record, ok)`; explicit subscription columns | settled (ING-15) | A B |
| 2026-05-15 | `8ceca4b` | #740 | FIX | events enriched against deleted billable metrics | `fff5858` dropped the soft-delete scope | explicit `deleted_at IS NULL`; tests restored, pinning `SELECT *` | settled; `SELECT *` residual | C B |
| 2026-05-18 | `9ef876a` | #738 | FIX | flat_filters query issue (ING-123, no body) | query lacked `organization_id` | org predicate | removed; leak-or-perf is OD-9 | D |
| 2026-05-21 | `3ac94a2` | #741 | FIX | SQLSTATE 0A000 after a view alter (ING-143) | `SELECT *` on a view | pin columns | removed | B D |
| 2026-05-28 | `9921879` | #745 | TEST | – | n/a | two `GetEnvAsBool` tests (external contributor) | n/a | M |
| 2026-07-27 | `b4ad153` | #768 | FIX | alerts not refreshed for backdated recurring events | no subscription at the past timestamp → no flag | recurring fallback to `time.Now()` | settled; parity differences, see `rails-go-parity` | G |
| 2026-08-20 | `0b56915` | #774 | FIX | usage cache expired the wrong key (ING-543) | Go picked another filter than Ruby on ties | Ruby-equivalent tie-break | removed `d9c32b6` | D F |
| 2026-08-27 | `02a4bc8` | #785 | FIX | `context canceled` Redis errors during rolling restarts | stores captured the process ctx (cancelable since `b6d3616`) | ctx per call | settled | F G J |
| 2026-09-14 | `2fd8e8b` | #766 | REMOVAL | (no body) | Go-side expiry no longer wanted (inferred: Rails lazy validation) | ChargeCache, CacheService, cache Redis connection removed | removed; dead remnants residual | F |
| 2026-09-18 | `d9c32b6` | #797 | REMOVAL | "the main database load coming from the service" | per-event non-materialized `flat_filters` view | flat filters, expanded topic, reprocess branch, target wallet, grouped_by removed; pay-in-advance from `charges` | settled; Rails leftovers (OD-8) | B D E M N |
| 2026-09-18 | `5308258` | (supersedes #800) | FEAT | staging needs a hardened image; #800 lost to a force-push | Dockerfile lived in private lago-deploy | `Dockerfile.staging` (Wolfi bases) | settled | X11 |

Not analysed row by row: 17 dependabot commits (`hist.sh --ep --count` minus `--humans`), all under
`events-processor/`. One of them matters: `932c06c` raised go.mod's `go` directive (chain L).

## Counts and people (as of 2026-10-01)

- Commits: 96 total, 79 human, 17 dependabot (`hist.sh --ep --count`, `hist.sh --ep --humans --count`).
- Authors (rename-aware): Vincent Pochet 62 of 79 human commits; with the `events-processor` path
  alone (no rename) the count is 55 of 72 (`hist.sh --ep --authors`). Bus factor: one maintainer.
- Ticket ids in messages: ING-15 (`9acd83e`), ING-123 (`9ef876a`), ING-143 (`3ac94a2`), ING-543
  (`0b56915`) (`incidents.sh --ep --tickets`).
- No `git revert` commit exists under events-processor; every removal was a forward commit
  (`incidents.sh --ep --reverts` lists only `b604769`, a hotfix).
- Best-written incident commits to imitate: `9acd83e`, `02a4bc8`, `d9c32b6` (symptom, cause, fix in
  the body). Most other bodies are empty or a squash list.
