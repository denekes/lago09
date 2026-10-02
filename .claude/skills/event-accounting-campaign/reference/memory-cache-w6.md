# W6 memory-cache correctness (badger snapshot + Debezium CDC): scope, measurements, gated phases

Read when you plan or review a change to `events-processor/cache/*.go`, `extra/debezium_config.json`, the
cache start-up in `events-processor/main.go:66-81`, or any cache-mode gate. Why this is in the campaign:
production runs memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)), and W6 owns its hardening
(DEFAULT APPLIED OD-20: the orchestrator assigned it on 2026-10-02; the owner may reassign it). The production CDC
configuration is OPEN DECISION OD-1b (owner): verify it first (W6-0). The as-is defects and their severity
live in `architecture-contract` (WP6-WP10); this file plans and gates the fixes. Code facts as of 5308258
(events-processor tree 83e012866f29); the working branch may carry skills-only commits on top.
Measured 2026-10-02 unless marked. Every fix here is CANDIDATE until merged with evidence.

## 1. Scope

| # | Item | Defect today | Evidence | Measured today (2026-10-02) | Target |
|---|---|---|---|---|---|
| 1 | Debezium column list (`architecture-contract` WP6) | `column.include.list` omits `charges.pay_in_advance`, `charges.accepts_target_wallet`, `billable_metrics.recurring`; a CDC update rewrites the whole cached row (`events-processor/cache/consumer.go:158`), so those fields become false: in-advance production (`events-processor/cache/charges.go:89-101`) and the recurring fallback (`events-processor/processors/events_processor/enrichment_service.go:57`) stop for every edited charge or metric. `accepts_target_wallet` is read by no Go code path beyond the model (`events-processor/models/charges.go:14,30`) | `extra/debezium_config.json:2`; models `events-processor/models/charges.go:13-14`, `events-processor/models/billable_metrics.go:51` | `smoke-binary.sh cache-cdc`: `tx_A ... in_advance=no` (one CDC `charges` row shaped from the repo list); `smoke-binary.sh cache`: `tx_A ... in_advance=yes` | cache-cdc `tx_A in_advance=yes`; a guard test that every column Go selects (`SelectFields` in `events-processor/models/*.go`) is in the list |
| 2 | CDC consumer client (WP10) | the broker env is passed as ONE seed (`events-processor/cache/consumer.go:28-31`), no SASL/TLS, no logger, while the main clients split brokers and add SCRAM/TLS/logger (`events-processor/config/kafka/kafka.go:31-67`); fetch errors loop forever (`consumer.go:66-74`); an undecodable CDC record is dropped and committed (`consumer.go:94-103`) | as cited | `kfake-run.sh cdc-brokers`: `brokers=1 ... visible in cache=true`, `brokers=2 comma_joined=true ... visible in cache=false` | `brokers=2` visible=true; SASL/TLS/logger through `kafka.NewKafkaClient`; a counter for dropped CDC records |
| 3 | Per-start consumer groups (WP10) | every start creates `lago_evp_<model>_<uuid>` (`consumer.go:27`): six new groups per start, a full CDC replay each time, orphan groups left on the broker | `consumer.go:27` | `smoke-binary.sh cache`: `consumer_groups: smoke_events-raw + 6 lago_evp_<model>_<uuid>` | 0 per-start groups (group-less consumption from the start, CANDIDATE) or stable names |
| 4 | Swallowed snapshot errors (WP7) | each `Load*Snapshot` result is ignored (`events-processor/cache/cache.go:78-106` return nil), so a failed table leaves the cache empty and the pod keeps consuming | `cache.go:78-106` | `smoke-binary.sh cache --no-expected --env DATABASE_URL=<empty scratch DB>`: 7 of 9 events DLQ `fetch_billable_metric(Key not found)`, `exit_after_sigterm=<nil>`, `panic_lines=0` | start-up fails fast (non-zero exit) when any snapshot table fails; nothing is consumed |
| 5 | Boundary precision (WP9) | cache compares `started_at`/`terminated_at` at full precision (`events-processor/cache/subscriptions.go:60-65`), DB mode and Rails at milliseconds (`events-processor/models/subscriptions.go:32-33`, `$API/app/services/events/post_process_service.rb:50-53`) | as cited; parity row `rails-go-parity` P3 | `smoke-binary.sh db`: `tx_H ... subscription_id="bbbbbbbb-…01"`; `smoke-binary.sh cache`: `tx_H ... subscription_id=""` (event in the start millisecond, `started_at` +500 µs) | cache = DB = Rails at the boundary millisecond |
| 6 | Prefix scan (WP8, same workstream) | the subscription lookup scans a raw key prefix, so external ids containing `:` leak into shorter ids | `events-processor/cache/subscriptions.go:46` | `architecture-contract` WP8 (scratch probe) | exact external-id match |
| 7 | Memory | every pod holds the whole snapshot in RAM (badger in-memory, `events-processor/cache/cache.go:37`), values stored as JSON (`cache.go:131-145`) | as cited; resource row `docs/architecture.md:262` ("Events Processor Worker", 2Gi; whether that row is this Go service is unclear) | `run.sh cache-bench -n 1000000`: `insert=13.66s (73208/s) heap_inuse_mb=406 rss_mb=792 lookup_ok=true` (18.5 s on a loaded host; subscriptions only) | a budget set by owner/ops from production object counts (UNVERIFIED here); RSS per 1M does not grow |

## 2. Gated phases (W6-0 .. W6-5)

<!-- evidence-check: off phase plan (CANDIDATE changes and gates); measurements in section 1 and section 4 -->
Every W6 PR also runs both ledgers: `scoreboard.sh --check-baseline` must show `moved=0` (W6 does not
change delivery), unless the PR is also an ADR-001 step.

| Phase | Change (CANDIDATE) | Class (`change-control`) | Depends on | Exit gate |
|---|---|---|---|---|
| W6-0 Measure + OD-1b | run the section 4 block; ask the owner for the production Debezium connector config (`column.include.list`), the CDC consumers' broker list and Kafka auth | C1 | nothing | section 4 outputs recorded; OD-1b answered, or still open and said so in every W6 PR |
| W6-1 Columns | add the three columns to `extra/debezium_config.json:2`; a Go test that the list covers every `SelectFields` column; the `diagnostics-and-tooling` cache-cdc row is regenerated from the new list (its expected file changes in the same PR) | C4 (`extra/debezium_config.json` path row; contract K9). DECIDED OD-4 (owner, 2026-10-02): no lago-api PR (the columns exist in `$API/db/structure.sql`); the production connector is an ops change (OD-1b) | W6-0 | `smoke-binary.sh cache-cdc` -> `tx_A ... in_advance=yes`; guard test green; production connector updated (ops evidence) |
| W6-2 CDC client + groups | build the six CDC clients with `kafka.NewKafkaClient` (split brokers, SASL/TLS, logger); consume without a per-start group; count dropped CDC records | C4 (group naming) | W6-0 | `kfake-run.sh cdc-brokers` -> `brokers=2 ... visible in cache=true`; `smoke-binary.sh cache` -> `+ 0 lago_evp_<model>_<uuid>`; a SASL case in the in-repo test (kfake SASL support UNVERIFIED) |
| W6-3 Fail fast | `LoadInitialSnapshot` returns the first error; `main.go` panics on it (startup contract: `architecture-contract` I14) | C3 (behaviour test) | W6-0 | the empty-DB smoke run exits before consuming (`exit_before_sigterm=exit status 2`, no `tx_*` output); normal smoke runs unchanged |
| W6-4 Boundaries | truncate both bounds to ms in the cache search; exact external-id match | C3; parity row owner `rails-go-parity` (P3) | W6-0 | `smoke-binary.sh cache` -> `tx_H ... subscription_id="bbbbbbbb-…01"` (= DB); `smoke-expected-cache*.txt` updated in the same PR; `rails-go-parity` subscription probe updated |
| W6-5 Memory | measure per object type; CANDIDATE reductions (store only the fields Go reads; badger options) | C1 (measure), C3 (code) | W6-0 + owner budget | `run.sh cache-bench` before/after; RSS per 1M subscriptions not above 792 MB (+10 % noise) unless the owner budget allows it |
<!-- evidence-check: on -->

Order: W6-0 first (OD-1b decides how urgent W6-1 is). W6-1 and W6-3 are the highest value: one silently
stops in-advance billing for edited charges, the other turns a partial start-up into a DLQ flood. The
`diagnostics-and-tooling` expected files (`fixtures/smoke-expected-*.txt`) are owned there: a W6 PR that
changes smoke output updates them in the same PR.

## 3. Cache miss vs CDC lag (open design point inside ADR-001)

A billable metric or subscription created in Rails reaches the cache only through CDC. An event that arrives
first gets `Key not found` (NonRetryable + NonCapturable: `events-processor/cache/cache.go:189-191`;
subscriptions `events-processor/cache/subscriptions.go:105-108`), so a billable metric miss is DLQ'd at once
(`fetch_billable_metric`) where DB mode would have enriched it, and a subscription miss enriches without a
subscription (smoke `tx_F` shape). ADR-001 classifies "not found" as PERMANENT. CANDIDATE: in cache mode, treat
a miss for a recent event (e.g. `ingested_at` within a few minutes) as TRANSIENT, so it goes through the retry
topic. Needs a measured CDC lag first (production metrics, UNVERIFIED) and is an ADR-001 parameter choice,
not a change of its classes.

## 4. Phase-0 cache-mode block and expected-today outputs (2026-10-02)

From the repo root; Postgres as for Phase 0 (`smoke-binary.sh` and the empty-DB run use scratch databases).
```bash
D=.claude/skills/diagnostics-and-tooling/scripts; S=.claude/skills/event-accounting-campaign/scripts
$D/smoke-binary.sh cache cache-cdc           # both "EXPECTED-TODAY: MATCH", exit 0, ~10 s
$S/run.sh accounting-probe -mode cache       # TOTALS rows=26 ... UNACCOUNTED=4, exit 4 (= expected)
$D/kfake-run.sh cdc-brokers                  # brokers=1 -> visible=true ; brokers=2 comma_joined=true -> visible=false
$S/run.sh cache-bench -n 1000000             # n=1000000 insert=13-19s heap_inuse_mb=~406 rss_mb=~792
u=$($D/scratch-pg.sh create w6_empty_snapshot) && $D/smoke-binary.sh cache --no-expected --env DATABASE_URL="$u"; $D/scratch-pg.sh drop w6_empty_snapshot
                                             # 7 of 9 tx lines dlq=fetch_billable_metric(Key not found); exit_after_sigterm=<nil>
```
What differs from DB mode in the smoke result (`smoke-expected-db.txt` vs `-cache.txt` vs `-cache-cdc.txt`):
<!-- evidence-check: off probe output; re-run the block above to re-verify -->
| Line | db | cache | cache-cdc | Meaning |
|---|---|---|---|---|
| `tx_A` | `in_advance=yes` | `in_advance=yes` | `in_advance=no` | item 1: one CDC update zeroes `pay_in_advance` |
| `tx_B` | `dlq=fetch_billable_metric(record not found)` | `…(Key not found)` | `…(Key not found)` | same disposition, different text (DLQ cause parsers must accept both) |
| `tx_H` | `subscription_id="bbbbbbbb-…01"` | `subscription_id=""` | `subscription_id=""` | item 5: boundary millisecond |
| `consumer_groups` | `+ 0 lago_evp_<model>_<uuid>` | `+ 6 …` | `+ 6 …` | item 3 |
<!-- evidence-check: on -->

Cache-mode ledger (`run.sh accounting-probe -mode cache`, identical on 3 runs and one `GOFLAGS=-race` run,
2026-10-02): the 7 cases with a cache-mode counterpart give the same fault-row outcomes as DB mode (cases 4,
5, 7 SENTRY_ONLY; 8 SKIPPED_RETRY; 9 REDELIVERED x2; 6 and 10 DLQ, case 10 with the cause text
`Key not found`); `TOTALS rows=26 ENRICHED=19 DLQ=2 REDELIVERED=1 LOST=0 SKIPPED_RETRY=1 SENTRY_ONLY=3
PENDING=0 ENRICHED+DLQ=0 UNACCOUNTED=4`. Cases 1-3 inject at the Postgres edge and have no cache-mode
counterpart: the cache returns only NonRetryable "not found" or, on a badger failure, a retryable error
that cannot be made transient from outside (`events-processor/cache/cache.go:177-197`).
