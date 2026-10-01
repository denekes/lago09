# Fix-after-fix chains, narrated

Read this when you are about to touch code that a chain covers (find it with
`scripts/chain.sh --for <path>`), or when a fix you are planning "feels obvious": most obvious fixes
here were already tried. Each chain lists every step in order: what the step tried, why it failed,
what finally held, what is still live in the code today, and the rule that stops a re-fight.

Code facts as of `5308258` (events-processor tree `83e012866f29`); the working branch may carry
skills-only commits on top. History facts verified 2026-10-01 in the history clone (`H`, 776 commits
from the fork remote). lago-api facts are at the pin `591ae90` (2026-09-08).
Replay any chain with `.claude/skills/failure-archaeology/scripts/chain.sh --named <ID>`.
Commits before `d5bce86` (2025-03-21) use the directory `events_processor/`: for `git show <sha>:<path>`
or `ls-tree` on them spell it so (`git -C "$H" show 4100da0:events_processor/config/kafka/consumer.go`).
Status words: **settled** (the fix holds), **removed** (resolved by deleting the feature),
**residual** (the class of bug is still possible; current code cited), **open** (the defect is live).

Contents: events-processor chains A–N, then infra chains X1–X13.

---

## A. Kafka commit path (13 months, ended in a production segfault, ING-15)

Files: `events-processor/config/kafka/consumer.go` (`consume`, `processRecordsAndCommit`,
`findMaxCommitableRecord`, `poll`/`pollRecords`), `processors/events_processor/processor.go` (retry branch).
Reproduce: `scripts/chain.sh events-processor/config/kafka/consumer.go 'findMaxCommitableRecord|commitableRecords|CommitRecords|^[[:space:]]+return$'`
prints exactly `4100da0 cec0eb2 600e195 b604769 b6d3616 9acd83e`.

1. `4100da0` (2025-03-11, #474). Each partition goroutine processed a batch and committed its last
   record. A failed record was still committed, but every processing failure went to the DLQ
   (`go produceToDeadLetterQueue(event, result)` in `events_processor/processors/events.go` at
   `4100da0`; an unparseable record was only logged). No retry existed.
2. `cec0eb2` (2025-03-31, #502). Tried: retry transient failures. Added `Retryable`/`Capture` flags,
   a 12 h window on `ingested_at`, and `findMaxCommitableRecord` to commit only the processed prefix.
   Failed because the partial-batch branch ended in a stray `return` inside the `for { select {} }`
   of `consume()`. Any batch with an unprocessed record ended the partition goroutine without
   committing. `poll()` then blocked forever on `cg.consumers[tp].records <- p.Records` (an unbuffered
   channel), which stalls every partition of that consumer. VERIFIED by reading
   `git show cec0eb2:events-processor/config/kafka/consumer.go`; the runtime impact is inferred, UNVERIFIED.
3. `656c829` (2025-04-10, #511). Unparseable records were never in the processed list, so they also
   hit that `return`. They are now appended to the processed list ("will fail forever"), committed
   and sent to Sentry. No DLQ message is written. That is still true today (step "residual" below).
4. `600e195` (2025-11-07, #628). A refactor moved the body into `processRecordsAndCommit`. The same
   `return` now only skipped the commit, and the goroutine survived. The same refactor split
   `poll()`/`pollRecords()`, so the `return` on "client closed" left only the inner function and
   `poll()` looped forever.
5. `b604769` (2025-11-10, #629, `hotfix`). Three days later: `pollRecords` returns `bool` and `poll()`
   exits on `false`.
6. `b6d3616` (2025-11-25, #608). Graceful shutdown. Removed the `return`, so the partial-batch branch
   now committed `[]*kgo.Record{record}`. When the FIRST record of a batch failed retryably,
   `record` was `nil`.
7. `9acd83e` (2026-05-06, #735, ING-15). Commit body: "findMaxCommitableRecord returned nil and the
   caller wrapped it in a slice passed to CommitRecords, segfaulting the pod inside franz-go".
   Fix: `(record, ok)`; skip the commit when `ok` is false. The nil-commit bug lived 162 days
   (2025-11-25 to 2026-05-06).

What held: the `ok` guard (`events-processor/config/kafka/consumer.go:94-100`) and the table test
`TestFindMaxCommitableRecord` (`config/kafka/consumer_test.go:18`).

Residual (open, delivery semantics, OPEN DECISION OD-2 (owner)):
- A skipped commit relies on "records will be re-polled after the next rebalance"
  (`consumer.go:97`). franz-go keeps fetching forward, so a later fully processed batch on the same
  partition commits past the failed offset. The failed record is then never retried and never sent
  to the DLQ (`consumer.go:89-104`, `processor.go:74-79`).
- Unparseable records: committed, Sentry only, no DLQ (`processor.go:49-59`).
- No test drives `processRecordsAndCommit` (`grep -rn processRecordsAndCommit --include=*_test.go events-processor` is empty).

Do not re-fight: never change commit or delivery code without a test that drives
`processRecordsAndCommit` (kfake harness, see `diagnostics-and-tooling`), a design note, and owner
sign-off (change-control N7). Never pass a computed record to `CommitRecords` without the `ok` check.
"Commit every record" is the `4100da0` design (every failure DLQ'd) that `cec0eb2` replaced on purpose
("…and avoid commit"); today it turns REDELIVERED into LOST (accounting-probe UNACCOUNTED 5 -> 7, see
`event-accounting-campaign` "Wrong paths"). The fix for the residual belongs to
`event-accounting-campaign` (W1).

## B. `SELECT *` and pgx cached plans (SQLSTATE 0A000)

Files: `events-processor/models/subscriptions.go`, `models/billable_metrics.go`, the deleted `models/flat_filters.go`.

1. `4100da0`. `FetchSubscription` joined `customers`; gorm emitted an explicit, table-qualified
   column list and the sqlmock test pinned it. `FetchBillableMetric` was a bare gorm `First`
   (`SELECT *`) from day one, and its test pinned `SELECT * FROM "billable_metrics"`
   (`git -C "$H" log -S'SELECT * FROM "billable_metrics"' --oneline -- events-processor events_processor`
   → `8ceca4b`, `fff5858`, `4100da0`).
2. `bd92069` (2025-11-18, #634). Tried: cut DB load by filtering on `subscriptions.organization_id`
   instead of joining `customers`. Side effect: gorm now emitted `SELECT *`, and the test was
   re-pinned to `SELECT *`. Every Rails migration that adds a column to `subscriptions` then
   invalidated pgx's cached prepared plan (SQLSTATE 0A000).
3. `9acd83e` (2026-05-06, ING-15, second half of the same PR as chain A). Explicit column list from
   `schema.Parse` (`models/subscriptions.go:37`).
4. `8ceca4b` (2026-05-15, #740). The deleted-billable-metric fix (chain C) restored the 101-line
   test file that `fff5858` had deleted. The restored test still pins
   `SELECT * FROM "billable_metrics"` (`models/billable_metrics_test.go:15`), nine days after
   `9acd83e` documented why `SELECT *` breaks. Nobody applied the subscriptions fix to billable metrics.
5. `3ac94a2` (2026-05-21, ING-143). Same fix for the `flat_filters` view ("a flat_filters view alter
   no longer invalidates pgx cached plans").
6. `d9c32b6` (2026-09-18). The view and its query were removed (chain D).

Residual (open): `FetchBillableMetric` uses gorm `First` = `SELECT *`
(`events-processor/models/billable_metrics.go:59-66`), pinned by `models/billable_metrics_test.go:15`
and `processors/events_processor/processor_test.go:91`. A column-add migration on `billable_metrics`
in lago-api can trigger the same 0A000 errors.

Do not re-fight: explicit column lists on every query against a Rails-owned table or view; pin the
exact SQL in the sqlmock test (change-control N4). Do not "simplify" a query by dropping a join or a
`Select(...)` without checking the SQL gorm now emits.

## C. Soft-delete scope lost in a refactor

1. `4100da0`. Models used `gorm.DeletedAt`, so gorm silently added `deleted_at IS NULL`.
2. `fff5858` (2026-04-27, #639, memory cache). Changed the field type to `utils.NullTime` (needed for
   Debezium JSON) and deleted 101 lines of billable-metric tests. The implicit scope disappeared.
   Deleted billable metrics were then matched again.
3. `8ceca4b` (2026-05-15, #740). Explicit `deleted_at IS NULL`; tests restored. Exposure: 18 days.

Settled for billable metrics and charges (`models/charges.go:36,54`). Class residual: nothing
mechanical catches a lost gorm convention (no lint, no query-shape test beyond sqlmock pins).

Do not re-fight: every read of a soft-deletable Rails table carries `deleted_at IS NULL` in the query
string (change-control N4). When you change a struct field's type, check what gorm magic it carried
(`DeletedAt` scope, `TableName`).

## D. `flat_filters` per-event resolution saga (15.3 months, 19 commits, removed)

`scripts/chain.sh events-processor 'FlatFilter|flat_filters'` lists 19 commits from `3a6ed00`
(2025-06-09) to `d9c32b6` (2026-09-18). Sequence:

1. `3a6ed00` (#542). Introduced to compute Rails charge-usage cache keys in Go (chain F).
2. `f1d369a`, `26e7c7c` (2025-08-11). Pre-aggregation: per-charge fan-out with charge and filter ids,
   `grouped_by` from `pricing_group_keys`.
3. `d7ee4c2` (2025-08-14). Pay-in-advance derived from flat filters (chain E).
4. `3dae52f` (2025-08-25). `events_enriched_expanded` producer; its topic env var made mandatory
   (panic if unset) for every events-processor deployment, self-hosted included, until `d9c32b6`.
5. Same day and next day: `36b1e23` (nil `FlatFilter` panic when no charge matched), `0c46c8a`
   (`grouped_by` nil, and one map shared by every fan-out copy). `45b216d` (2025-10-14): flaky test
   from map iteration order in the fan-out.
6. `75b9cbc` (2025-11-17) enabled the flow; `2cf3864` (2026-02-19) added `target_wallet_code`;
   `2fec4db` (2026-03-03) fixed `ToDefaultFilter` dropping pricing group keys; `6048999` added a
   reprocess pipeline.
7. `9ef876a` (2026-05-18, ING-123). The `flat_filters` query lacked `organization_id`. Whether this was
   a cross-tenant correctness leak or a performance issue: OPEN DECISION OD-9 (owner), UNVERIFIED (no
   commit body).
8. `3ac94a2` (ING-143). `SELECT *` on the view broke cached plans (chain B).
9. `0b56915` (2026-08-20, ING-543). Go picked a different filter than Ruby on ties, so it expired a
   cache key the Rails reader never wrote. Fixed with a Ruby-equivalent tie-break (most keys; then
   oldest `charge_filters.updated_at`, matching `$API/app/models/charge_filter.rb:22`
   `default_scope -> { kept.order(updated_at: :asc) }`).
10. `d9c32b6` (2026-09-18, #797). Removed 2,610 lines. Commit body: "a non-materialized view over five
    joins plus a `jsonb_object_agg`, and the events processor ran it once per event … That is the main
    database load coming from the service." The only consumer, the expanded topic behind
    `enriched_events_aggregation`, was "off everywhere".

Residual: the memory cache still snapshots and CDC-consumes billable-metric filters, charge filters
and charge filter values (`events-processor/cache/cache.go:94-119`), and no processor reads them.
lago-api at the pin `591ae90` (2026-09-08) still ships the `events_enriched_expanded*` ClickHouse migrations
(`$API/db/clickhouse_migrate/20250814124830_create_events_enriched_expanded_queue.rb:9` reads
`LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC`) and the `enriched_events_aggregation` flag
(`$API/app/config/feature_flags.yaml:5`). Impact depends on OD-8.

Do not re-fight: no per-event charge or charge-filter resolution in Go, and no per-event query of a
non-materialized view (change-control N8). If pre-aggregation returns, it needs a materialized or
cached source plus a written Rails-parity spec for filter matching (key presence, value
stringification, tie-breaks) and owner sign-off.

## E. Pay-in-advance detection, full circle

1. `4100da0`: `AnyInAdvanceCharge` on the `charges` table.
2. `d7ee4c2` (2025-08-14): moved onto flat filters (per-filter `PayInAdvance`); `models/charges.go` deleted.
3. `36b1e23` (2025-08-25): nil-pointer panic when no charge matched.
4. `d9c32b6` (2026-09-18): back to the `charges` table, `HasPayInAdvanceCharge`
   (`events-processor/models/charges.go:47-54`: `pay_in_advance IS TRUE AND deleted_at IS NULL`),
   only for events with a subscription that were not post-processed by the API
   (`processors/events_processor/processor.go:115-116`).

Settled. Rule: "the plan has at least one non-deleted pay-in-advance charge for this billable metric",
as in Rails `PostProcessService#charges`. It is not per filter. In memory-cache mode the same check
reads cached charges whose Debezium column list lacks `pay_in_advance`
(`extra/debezium_config.json`; production use is OPEN DECISION OD-1 (owner); the hardening is unowned,
OD-20, `architecture-contract` WP6).

## F. Go-side expiry of Rails charge-usage cache keys (15.2 months, removed)

1. `3a6ed00` (2025-06-09, #542). Go computes the Rails cache key and `DEL`s it.
2. `8d61fa7` (next day). Cache Redis connection failed in prod: TLS forced on. `UseTLS:false`.
3. `4cd30f2` (2025-10-17, #610). `DEL` ran before ClickHouse ingested the event, so Rails refilled the
   cache with stale data. Changed to `EXPIRE 5s` (code comment: "to take clickhouse propagation time
   into account").
4. `3cd78f1` (2025-10-23, #611). In dev, EP used Redis DB 0 and the API DB 3, so the cache never
   expired in dev for 4.5 months (`LAGO_REDIS_CACHE_DB=0` came with `3a6ed00`).
5. `42615c9` (2026-03-27) 15 s; `fb6401d` (2026-04-20) 10 s.
6. `0b56915` (2026-08-20, ING-543). The wrong key expired: Go and Ruby chose different filters (chain D).
7. `02a4bc8` (2026-08-27). Context per call (chain J).
8. `2fd8e8b` (2026-09-14, #766, no commit body). Removed the Go-side expiry entirely. The rationale
   (Rails lazy, watermark-based validation behind `lazy_charge_usage_cache`,
   `$API/app/services/events/post_process_service.rb:85`) is inferred, UNVERIFIED.

Residual (dead code): `EXPIRATION_TIME`, `Cacher`, `CacheStore`, `ExpireKey`
(`events-processor/models/stores.go:15,75-104`), `tests/mocked_cache_store.go`, and the unused
`envLagoRedisCache*` constants (`processors/main_processor.go:40-43`). Cache correctness for ClickHouse
orgs not on `lazy_charge_usage_cache` depends on OD-8.

Do not re-fight: Go never computes Rails cache keys or re-implements Rails resolution per event
(change-control N8). Any key-format coupling breaks silently, as ING-543 showed.

## G. Subscription refresh flag (two-repo Redis ZSET contract)

1. `7421650` (2025-04-07, #500). Redis `SADD subscription_refreshed`; Redis becomes mandatory. Shipped
   with the env typo `LLAGO_REDIS_STORE_PASSWORD`.
2. `69ec50d` (same day). Typo fixed; timeouts; TLS when `ENV=production` (chain H).
3. `fa5b45f` (2025-08-14). `SubscriptionRefreshService` extracted.
4. `42615c9` (2026-03-27, #720). The set was drained immediately, so refresh ran before data landed
   (inferred from the constant name `CLICKHOUSE_MERGE_DELAY`). Now `ZADD subscription_refreshed_v2`,
   member `org:sub|bucket`, score = now, 15 s bucket.
5. `fb6401d` (2026-04-20). 10 s bucket (`SUBSCRIPTION_BUCKET_DURATION`, `models/stores.go:16`); Rails
   matches (`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:7,14`).
6. `b4ad153` (2026-07-27, #768). Backdated events on recurring metrics found no subscription, so
   nothing was flagged. Fallback to the subscription active now
   (`processors/events_processor/enrichment_service.go:57-58`). Its ordering and status filter differ
   from Rails `fallback_subscription` (`$API/app/services/events/post_process_service.rb:68-76`:
   `.active`, `order(started_at: :desc)`); see `rails-go-parity`.
7. `02a4bc8` (2026-08-27). Context per call.

Settled. Do not re-fight: ZSET name, bucket and member format change only together with lago-api,
under a new versioned name (`_v3`) and a planned deploy order (change-control N6, OD-4).

## H. Redis TLS configuration

1. `69ec50d`: TLS iff `ENV=production`, with `InsecureSkipVerify: true`.
2. `3a6ed00`: cache store TLS set after construction. 3. `8d61fa7`: cache TLS off.
4. `a918f60` (2025-10-29, #613): `LAGO_REDIS_STORE_TLS` / `LAGO_REDIS_CACHE_TLS`; `ENV=production`
   kept as a deprecated fallback (`processors/main_processor.go:84-85`).

Settled. Residual: TLS always skips verification (`events-processor/config/redis/redis.go:42-45`);
`rediss://` is stripped but does not enable TLS (`redis.go:26`). See `config-and-flags` and
`security-and-supply-chain`. Rule: configure TLS with the explicit variable; never tie new behaviour to `ENV`.

## I. Timestamp parsing

1. `4100da0`: numeric timestamps only. 2. `cec0eb2`: `CustomTime` for `ingested_at`.
3. `d7d76be` (2025-04-11): `ingested_at` sent as a unix-timestamp string accepted.
4. `76c1b3b` (2026-03-05, #709): RFC3339 `timestamp` accepted. Before, those events went to the DLQ as
   non-retryable.

Residual (open): `ToTime` computes nanoseconds with float math, and the RFC3339 branch returns without
`.In(time.UTC).Truncate(time.Millisecond)` (`events-processor/utils/time.go:20-29` vs `:48`). Owned by
`rails-go-parity` (measurement) and `event-accounting-campaign` W3 (fix). Rule: any parser change must
keep every Rails producer format working (float seconds string, ISO with ms and no `Z`, `%s.%3N`); see
`rails-go-parity` for the exact producer lines.

## J. Concurrency, shutdown and context scoping

1. `4100da0`: fire-and-forget `go produce…` with a WaitGroup; a record could count as processed before
   its produce finished.
2. `a15bd3b` (2025-11-06, #624): errgroup; `processEvent` waits (`processor.go:100-101`).
3. `b6d3616` (2025-11-25, #608): signals cancel a root context. The flag and cache stores had captured
   the process context at construction since `7421650` (harmless while it was `context.Background()`),
   so every in-flight Redis write now failed with `context canceled` on SIGTERM.
4. `02a4bc8` (2026-08-27, #785): "Redis writes now receive the context of the record being processed"
   (in code: the batch context that `processRecordsAndCommit` passes to every record); connection
   setup keeps the process context. Exposure: 275 days.

Settled. Rule (change-control N5): per-record side effects (Redis, produce) use the batch context that
`processRecordsAndCommit` creates (`context.Background()`, `events-processor/config/kafka/consumer.go:83`)
and passes to every record, never the process/signal context that SIGTERM cancels; so in-flight events
survive shutdown.

## K. Tracing provider

`222691f` (2025-09-15): OTel gated on `OTEL_EXPORTER_OTLP_ENDPOINT` instead of `ENV=production` →
`475761d` (2025-11-27): provider abstraction on dd-trace-go v1 (go.mod +235/−8 lines, pulling confluent,
sarama and segmentio Kafka clients in as indirect deps) → `a9c9eb5` → `1f2d36e` (next day): dd-trace-go
v2 + Kafka hooks; those indirect clients are gone. Settled. Residual: `// TODO: fetch version`
(`config/tracing/tracer.go:115`, open since `475761d`). The Kafka client has always been franz-go;
the one-day confluent/sarama entries in go.mod were transitive only.

## L. Toolchain and lago-expression pins

1. `07d1d4d` (2025-03-14): lago-expression was cloned at HEAD; tests broke on a float timestamp. Pinned `v0.1.4`.
2. `d589940` (2025-09-10): `air@latest` required Go 1.25 → pinned `air`/`dlv`.
3. `5077151` (2026-01-02): lago-expression `v0.2.0` in three files → `e8bbd60` (same day, "Fix prod
   release"): `events-processor/Dockerfile` was still `rust:1.82` → `rust:1.85` (the exact Rust
   requirement is inferred, UNVERIFIED).
4. `d4e3665` (2026-01-08): `git clone --tags` ("make sure git clone get tags updated"; a cached clone
   layer that predated the tag is inferred, UNVERIFIED).
5. `932c06c` (2026-04-09, dependabot otel/sdk bump) raised go.mod to `go 1.25.0`; `50015b0` 50 minutes
   later moved CI and Dockerfiles to Go 1.25.

Settled; enforced by review only. Rule: change-control N3 (the ref lives in 4 places and moves with the
Rust image; no `@latest`; do not "fix" go.mod's `expression-go v0.1.4`). Watch dependabot PRs that touch
the `go` directive.

## M. Env-var contract churn in events-processor

`f277b44` (2025-03-21) added `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNEXIONS` (a parse error set the
pool size to 0) → `7421650` silently renamed it to `..._CONNECTIONS` and added the `LLAGO_` typo →
`69ec50d` fixed the typo → `3dae52f` (2025-08-25) made `LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC`
mandatory → `27169be` (2025-11-27): `LAGO_KAFKA_TLS=1` had been ignored (`== "true"`), now
`GetEnvAsBool` → `f6852c0` (2025-12-15, 112 days after `3dae52f`) dev compose finally created the
expanded topic → `d9c32b6` removed the topic and its variable.
Residual: `GetEnvAsBool` returns the default on any unparsable value (`events-processor/utils/env.go:35-43`);
`events-processor/README.md` still lists the removed `LAGO_REDIS_CACHE_URL`. Rule: env names are a
contract with every deployment; renames need a migration note and a fallback (see `config-and-flags`).

## N. Property values stringified with `%v` (open)

`4100da0`: `value = fmt.Sprintf("%v", properties[field])` → `26e7c7c`: `grouped_by` built the same way →
`3dae52f`: `count` value becomes `"1"` → `2fec4db` (2026-03-03): a nil `grouped_by` property now yields
`""` instead of `"<nil>"`, but the value path was not fixed → `d9c32b6`: `grouped_by` removed.
Today `events-processor/processors/events_processor/enrichment_service.go:114` still formats with `%v`:
a scratch `go run` of the same expression gives `1000000 → "1e+06"`, `12345678 → "1.2345678e+07"`,
`null`/missing `→ "<nil>"` (VERIFIED 2026-10-01). Status open; owned by `event-accounting-campaign`
W2 and `rails-go-parity`; any ClickHouse schema answer is OPEN DECISION OD-3 (owner).
Rule: the `2fec4db` lesson is that the nil case was seen and patched in one call site only. Fix the
class, with a corpus test, not one call site.

---

## X1. All-in-one image (`docker/Dockerfile`) breaks on release day

The image is built only by `.github/workflows/release-docker-image.yml` on `release: released` (or a
manual dispatch), never on a PR. Each break below was found on, or after, a release.

| Step | Date | What broke | Why | Fix |
|---|---|---|---|---|
| `52ab3b3` → `023bfe1` → `c91af2b` | 2025-02-12 17:25 / 17:31 / 17:44 | first release workflow failed twice | wrong `needs:` job id; checkout without `submodules: true` | fixed within 19 min |
| `e07e182` → `d0099a9` → `9eb8c3b` → `92b1af2` | 2025-05-13..16 | image broken after the Ruby 3.4 move | Ruby ARG behind lago-api; Ruby 3.4 needs `libyaml-dev`; `packages.redis.io` `redis` package; missing `LAGO_ENCRYPTION_*` keys | pin Ruby, add libyaml, Debian `redis-server`, generate keys in `runner.sh` |
| `14fa1e0` → `b6b98c8` | 2025-08-19 → 09-15 | v1.33.0 (2025-08-27), v1.33.1 (08-28), v1.33.2 (09-08): no `getlago/lago` image (Docker Hub 404, checked 2026-10-01) | `14fa1e0` (Ruby 3.4.4 → 3.4.5) moved `ruby:*-slim` from bookworm to Debian trixie (today's Docker Hub digests: `3.4.5-slim` == `-trixie`, see `release-and-images`; that it already did on 2025-08-27 is inferred): no `postgresql-15`, no `software-properties-common` | `postgresql-17` (`b6b98c8`); v1.33.3 (2025-09-15) is the first image after the break |
| `218c9c9` → `18b26d0` | 2025-10-29 → 10-30 | v1.35.0 build: `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY`, then `tsc: not found` with `CI=true` | failed in the `corepack prepare pnpm@latest` / `pnpm prune` step; body: "seems to be related to the pnpm version update". Which pnpm ran is UNVERIFIED: lago-front pinned `packageManager: pnpm@10.18.3` at v1.35.0, and `pnpm@latest` sets only corepack's global default | drop `pnpm prune --prod`; `.dockerignore` for `front/node_modules`, `api/.env`. `getlago/lago:v1.35.0` pushed 2025-10-30T16:20Z, after the fix |
| `9faa659` → `c6abc1e` | 2025-12-09 → 12-11 | v1.37.0 image two days late | runner labels `linux/amd64` / `lago-runner` (in place since `52ab3b3`) stopped being served (inferred) | `ubuntu-latest`; image pushed 2025-12-11T09:03Z |
| `fd77a74` | 2026-02-03 | signup seed failed in the image (inferred from title) | lago-api needed `roles:seed_predefined` first | `docker/runner.sh:90-91` |
| `57508c2` → `074fc9a` → `558814a` | 2026-03-23 → 04-07 11:05 → 11:25 | v1.45.0 build broke | Bundler 4.0.4 (from `57508c2`) removed `bundle install --without`; latent 15 days | `bundle config set without` (`docker/Dockerfile:33`); v1.45.1 cut the same day |
| v1.48.0, v1.49.0, v1.50.0 | 2026-06-10 / 06-29 / 07-07 | `getlago/lago` has no image for these tags (Docker Hub API 404, checked 2026-10-01) while `getlago/lago-events-processor` has all three | UNVERIFIED (workflow logs not reachable from here) | none; v1.48.1 and v1.51.0 exist (other image gaps, e.g. `getlago/lago-events-processor:v1.41.2`: `release-and-images`) |
| `01cfbc6` | 2026-08-27 | v1.52.1 bump moved only the compose tags | its gitlinks are lago-api/front v1.52.0 (`731388f`, `dbde527`) | none: `getlago/lago:v1.52.1` was built from v1.52.0 api/front (inferred from `submodules: true` at the tag) |
| `ba292b6` → `b267320` → `f719ef1` | 2026-09-08 16:31 → 17:04 → 17:20 | v1.53.0 | Node 20 too old for front; Ruby 4.0.2 vs lago-api's 4.0.6 (inferred; no bodies) | Node 24, Ruby 4.0.6; `getlago/lago:v1.53.0` pushed 15:26Z = 17:26 +0200, after both fixes |

Residual (class open): no PR-time build of `docker/Dockerfile`; `corepack prepare pnpm@latest` still
at `docker/Dockerfile:12` (inert while lago-front pins `packageManager`; a conditional risk if front
drops it); missing tags were never backfilled (OPEN DECISION OD-10); the PGDG apt line at
`docker/Dockerfile:43-44` is broken (`tee /etc/ap`, `ppc64e1`, wrong keyring name) and the build works only because Debian trixie ships `postgresql-17`;
`docker/redis.conf` unused since `9eb8c3b` while `docker/runner.sh:40` still `sed`s a placeholder into
the stock config. Release mechanics and the target fix (PR-time `push: false` build) belong to
`release-and-images`; live triage to `debugging-playbook`.

Do not re-fight: when lago-api or lago-front change Ruby, Bundler or Node, bump `docker/Dockerfile`
ARGs in the same release PR (allowed in the bump PR; `precommit-guard.sh --release` WARNs
G1-release-shape, so explain it in the PR, change-control), and dispatch the image build before tagging. A `workflow_dispatch`
run checks out the ref it was dispatched on (the default branch unless you pick the tag), whatever
its `version` input says (`release-docker-image.yml:28-30`: `actions/checkout` with no `ref:`).

## X2. 2022 deploy-preview workflows iterated on `main` (removed)

`4aaa93b` (2022-03-21) added `.github/workflows/deploy-preview.yml`. Over 50 days, 42 commits touched
`.github/workflows/` (35 of them `deploy-preview.yml`; `git -C "$H" log --oneline 4aaa93b^..42d40cd -- .github/workflows | wc -l`
→ 42); 19 subjects say "fix" or "typo" (indentation,
helm repo, redis, porter names, e.g. `f097644`, `bbd8895`, `dcd09b1`, `c6e1748`, `97c9997`, `0d4d18f`).
`42d40cd` (2022-05-10) "remove deployments from public repo" deleted them. Lesson: a workflow can only
be tested by running it, so prototype on a branch with `workflow_dispatch`; deploy pipelines live in
the private lago-deploy repo now.

## X3. `deploy/deploy.sh` installer

1. `8a6ce39` (2025-03-22): installer added. A bare `👉 Docker Compose: …` line (no `echo`) is executed
   as a command when Compose is missing.
2. `cd9f0fa` (2025-05-20): production profile; `check_domain_dns` is called at line 212 but defined at
   line 277 (verified with `git show cd9f0fa:deploy/deploy.sh | grep -n check_domain_dns`), so Light and
   Production fail with `command not found`. Same commit pinned `deploy/*.yml` to `v1.27.1`.
3. `d54c463` (2025-07-22): local env download removed.
4. `2453945` (2026-09-03, #762, external contributor): function moved before use, `$pid` quoted,
   `echo` added. The ordering bug lived 15.5 months (471 days); the missing `echo` 17.4 months.

Residual (open, verified at HEAD): downloads go to `docker-compose.yml` (`deploy/deploy.sh:169,179,190`)
but the run uses `-f docker-compose.local|light|production.yml` (`:314-326`); running-project
detection captures nothing because stdout is redirected inside `$(…)` (`:106`); `check_command "docker
compose"` (`:58`) can never succeed; `deploy/*.yml` still pin `getlago/api:v1.27.1`; Pages republishes
only when `deploy/deploy.sh` changes (`.github/workflows/gh-page.yml:7-8`). Owned by `run-and-operate`.
Rule: `bash -n` passes on all of these; only an end-to-end run catches them.

## X4. Dev compose startup and init

1. `2747b04` (2023-09-22, #283): `lago_test` init script mounted from `./pg-init-scripts` (real path
   `./scripts/pg-init-scripts`), so it never ran.
2. `c80a7b5` (2025-09-03, #580): random `lago up -d` failures (migrate could not reach Redis or
   ClickHouse; topic creation refused) → health conditions. `5477e39` (next day): `rpk topic create` is
   not idempotent → `scripts/create-topics.sh`.
3. `e5392e9` (2025-11-04 17:05, #621): path fixed 25.4 months after `2747b04`; unused `bootstrap.sh` from `52ab3b3` removed.
4. `fc70e75` (2025-11-04 17:07, #622): the events-processor service still had bare `depends_on` lists → conditions.

Settled. Per change-control N12, infra edges use `service_healthy`, one-shot jobs
`service_completed_successfully`, and app→`api` edges `service_started` (10 explicit plus the bare
`front → api` list); `redpanda-console → redpanda` (bare) is the known exception (as of 2026-10-01;
re-check with the compose audit in SKILL.md "How to mine history"). Rule: change-control N12.

## X5. One env source of truth for dev

`688e4e7` (2024-02-07) added `LAGO_KAFKA_RAW_EVENTS_TOPIC=events-raw` per service →
`0ca6cdf` (2024-11-04, titled "Fix dev events_raw topic") set only `api-worker` to `events_raw`, while
the other services and `rpk topic create` used `events-raw` (verified in
`git show 0ca6cdf:docker-compose.dev.yml`) → `16c8b68` (2025-01-23) moved every service to one env
file with `events-raw` → `84b6eef` renamed it `.env.development.default`. That same file carried a
real `LAGO_LICENSE` value from `16c8b68` until `6dd7e56` (2025-03-07): 37 days on `main` after merge
`0a67ac0` (2025-01-29), up to 43 days if the feature branch was public from 2025-01-23 (UNVERIFIED); rotation is OPEN
DECISION OD-9 (owner); never print the value (change-control N11). Separately `3cd78f1` aligned
`LAGO_REDIS_CACHE_DB` (chain F step 3). Settled. Residual: `events-processor/README.md:41` still shows
`events_raw` as the example. Rule: change-control N12.

## X6. Submodule pointers moved outside release PRs

`f145388` (2025-03-14) "version should reflect tag" re-aligned the pins. `12b8101` (2025-11-04 13:03,
a Traefik `ws` entrypoint label fix) also moved both pins; `647de3e` reverted them at 16:18 the same
day (#620). Since 2025-01-01, 15 non-release commits moved a pin as a side effect (the 15 lines
printed by
`git -C "$H" log --since=2025-01-01 --no-merges --format='%h %s' -- api front | grep -viE 'bump|release|version|v1\.[0-9]'`
minus the release `b6bb37d`, plus `7251947` "Upgrade Clickhouse version"). Not counted: the two
corrective moves `f145388` (re-align to tag) and `647de3e` (revert), which the `version` filter
hides. Instance settled; class residual. Rule: change-control N1.

## X7. Image build workflows rewritten

`9d40e82` (2025-08-01) `release-processors-image.yml`; `6ff3a2f` added a duplicate
`release-processor-image.yaml` and `ca4a4fb` removed it 3 minutes later. Reusable
`docker-build-multi-arch.yaml`: `b61044f` (2025-11-13) with a `push` input → `fdfeb91` (2026-01-23)
removed it → `5070e24` (2026-08-25) re-added it ("No caller of this workflow does that today") →
`5ee8e98` OIDC `role-to-assume` (no caller). `4955f79` moved the EP ECR build onto it because the ECR
image "carried only an amd64 manifest". Settled; residual: `push: false` and `role-to-assume` have no
in-repo caller (`grep -rn 'push: false\|role-to-assume' .github/workflows` finds only the definition).
Owned by `release-and-images`.

## X8. Connectors image pipeline

`6a595fb` pinned redpanda connect. `76159bd` (authored 2026-08-24 17:33) dispatched to lago-deploy;
`2146a18` (authored 17:46) replaced it with a direct reusable-workflow call; both landed on `main`
together (committer 2026-08-25 10:59), so the dispatch workflow never ran alone ("Every push to its ECR repository came from
a person's local `docker push`"). `986f29b` (2026-08-26): two builds failed with `429 Too Many
Requests`; pull `docker.io/redpandadata/connect` directly. Residual: the ECR path never logs in to
Docker Hub, so base pulls stay anonymous (see `release-and-images`).

## X9. Redis custom port

`ed6f687` (2023-02-24, #200) added `--port ${REDIS_PORT}` but left the healthcheck on the default
port. `b1e40bd` (2025-05-09, #524) fixed the healthcheck 26 months later, in `docker-compose.yml:111`
only. Residual: `deploy/docker-compose.{local:105,light:129,production:129}` still run `redis-cli ping`
without `-p`. Rule: a fix to one compose family must be ported to the other two (root, dev, deploy).

## X10. Dev services added, then removed

`docker-compose.arm64.yml`: `22a1685` (2022-09-13) → `81a0df4` (2023-04-20), 38 commits of duplicated
tag bumps in 7 months. Meilisearch: `0e5937e` (2026-07-10) + `f0bb135` → `4230f1f` (2026-09-01, no
body), 53 days; lago-api at the pin `591ae90` has no Meilisearch reference. Mailhog → Mailpit `8f8334e`
(2026-09-03). Removed. Rule: do not re-add a dev service without a lago-api consumer at the pinned SHA.

## X11. Lost work and stray material

`c8f4133` (2023-10-05, #285, titled "Add sidekiq events worker") committed 269 files, 133 of them
Windows `:Zone.Identifier` files, plus Iceberg connector jars; `1035ffa` removed them 18 days later.
The blobs stay in history. `5308258` (2026-09-18): PR #800 "was force-pushed onto main before being
closed … the original is unrecoverable"; rebuilt from lago-deploy#3331. Rules: change-control N2;
check `git show --stat` before pushing.

## X12. GraphQL codegen split reverted

`15961be` (2024-09-24) split `CODEGEN_API` into two endpoints; `84013d6` reverted it the next day;
`dfb7b73` (2025-01-23) set `CODEGEN_API=http://api:3000/graphql` (today `docker-compose.dev.yml:108`).
Rule: env changes that depend on submodule code land with the submodule bump.

## X13. Compose env interpolation and default mistakes (2022–2024)

`d07887a` (2022-05-10, a CORS fix) wrote `LAGO_FRONT_URL"${…}` (a quote instead of `=`) in the
root compose; `9ca67f7` corrected it two days later.
`1a9bea1` (2022-06-23, `HOTFIX`): six `ENCRYPTION_KEY_DERIVATION_SALT={…}` lines lacked `$`.
`d2cadc7`, `f6581fb`, `bfb4d5f`, `5925130`, `a791efb`, `bf02b8d`: defaults missing or wrong,
producing warnings or empty values. `55540ce` (2024-01-11) corrected the spelling inside the
`LAGO_ENCRYPTION_*` placeholder defaults in `docker-compose.yml`; anyone running on those defaults got
different keys after upgrading (inferred, UNVERIFIED). Rule: grep for `={` after editing env blocks
(`grep -n '={' docker-compose*.yml deploy/*.yml` is empty today); never change a key-material default
in place; insecure placeholder defaults belong to `security-and-supply-chain`.
