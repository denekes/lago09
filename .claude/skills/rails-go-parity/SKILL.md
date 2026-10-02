---
name: rails-go-parity
description: "Contract between the Go events-processor and Rails lago-api plus ClickHouse, with parity probes: subscription matching, the enriched value string, decimal_value Decimal(38,26), unique_count, expression version, timestamps, payloads, drift between events-processor HEAD and the pinned lago-api. Use when a change or bug touches what both sides must agree on, or on \"1e+06\", \"<nil>\", a ClickHouse sum of 0 for large values, toDecimal128OrZero, an event 1 ms early. Not for the glossary (use domain-reference) or fixing divergences (use event-accounting-campaign)."
---
# Rails <-> Go parity: events-processor vs lago-api / ClickHouse

Go (`events-processor/`) re-implements a slice of Rails behaviour per event and writes data that Rails
and ClickHouse read. Nothing type-checks that contract across the two repos. This skill states it
row by row (Go `file:line` vs `$API/<path>:line`), labels each row MATCH or DIVERGE with evidence,
and ships the probes that re-prove it. Divergences are documented here and fixed in
`event-accounting-campaign`.

Facts verified 2026-10-01. Code facts as of `5308258` (events-processor tree `83e012866f29`); the working
branch may carry skills-only commits on top. lago-api at the pin `591ae90` (2026-09-08) unless marked.

## When to use / when NOT to use

Use it when you:
- change `events-processor/models/{event,subscriptions,charges,stores,billable_metrics}.go`, `utils/time.go`,
  `cache/subscriptions.go`, `cache/charges.go`, or `processors/events_processor/*.go`;
- add, rename or retype a JSON field on any of the four topics, or touch the Redis refresh flag;
- see "event billed 0", "unique count too high", "1e+06", "<nil>", "1 ms early", "no subscription found
  but Rails has one", "in-advance fee for an incomplete subscription";
- need to know what the pinned lago-api still expects from Go (`events_enriched_expanded`, `reprocess`,
  charge-usage cache);
- review a PR classified C3 or C4 (change-control defines the classes).

Do NOT use it for:
- term definitions and the end-to-end event lifecycle: use `domain-reference`;
- Go-only internals, the memory-cache/Debezium CDC path, commit and disposition rules: use `architecture-contract`;
- fixing a divergence, choosing between fixes, the fault-matrix ledger: use `event-accounting-campaign`;
- gates, change classes, the cross-repo PR protocol: use `change-control`;
- what an env var means (`LAGO_CLICKHOUSE_ENABLED`, TLS vars): use `config-and-flags`;
- generic probe harnesses (kfake, scratch PG, clickhouse-local wrapper): use `diagnostics-and-tooling`;
- DLQ error-code triage on a live system: use `debugging-playbook`;
- how the history clone and pinned checkouts work: use `research-methodology`.

## Terms

- **`$API`**: the pinned lago-api checkout, `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`.
  Read Rails here, never at lago-api `main`.
- **Pinned SHA**: the commit the umbrella `api` gitlink points to: `591ae90` (lago-api v1.53.0).
- **Contract row `P#`**: a stable id in `reference/contract-table.md`. A `parity-constants.sh` line id
  `P<n>[a-z]` guards row `P<n>` (`P20b` = row P20, the bucket); named ids (`TOPIC`, `KEYS`, `SCH1`, `DRIFT`…)
  are cited in that row's Evidence column.
- **MATCH / DIVERGE-VERIFIED / DIVERGE-CODE / HISTORICAL / INFO**: same by construction / difference shown by a
  probe / difference shown by reading code only / contract removed in `d9c32b6` or `2fd8e8b` / one-sided fact.
- **Post-processing**: the per-event side effects (refresh flag, pay-in-advance trigger) that exactly one
  side performs, chosen by `source_metadata.api_post_processed`.
- **`value` / `decimal_value`**: the string Go writes into `events_enriched.value`; ClickHouse derives
  `decimal_value Decimal(38,26)` from it with `toDecimal128OrZero(value, 26)`.
- **PG-store / CH-store org**, **billable metric (BM)**, **charge**, **subscription window**: see `domain-reference`.

## 1. Read first: Go HEAD is newer than the pinned Rails

| Side | Commit | Date |
|---|---|---|
| events-processor (last commit touching it) | `5308258` | 2026-09-18 |
| pinned lago-api (`git ls-tree HEAD api`) | `591ae90` | 2026-09-08 |

Two Go commits after the pin change what Rails can see:
- **`d9c32b6`** (#797): removed `flat_filters` (per-event charge/filter resolution), the
  `events_enriched_expanded` producer and its env var, the `reprocess` branch, `target_wallet_code` enrichment.
- **`2fd8e8b`** (#766): stopped expiring Rails `charge-usage/...` cache keys.

The pinned lago-api still reads `events_enriched_expanded` (when `pre_filter_events?` or
`enriched_events_aggregation`), still interpolates `LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC` in a
ClickHouse migration, still sends `reprocess`, and keeps CH-store orgs' charge-usage cache fresh only when
`lazy_charge_usage_cache` is on. Impact depends on **OPEN DECISION OD-8 (owner)**. The dev stack runs exactly
this pairing (`docker-compose.dev.yml:318-325` builds Go from source, `:179` mounts the `./api` submodule tree).
Full list with `$API` lines (drift items DR1-DR8) and rules: `reference/pinned-sha-drift.md`.

## 2. The contract at a glance

Full rows with Go and Rails `file:line`, evidence and consequence: `reference/contract-table.md`.
The K# column names change-control's cross-repo contract (`.claude/skills/change-control/reference/cross-repo-protocol.md`
section 1): changing a row with a K# follows that contract's paired-PR and deploy-order rules (change-control N6).

<!-- evidence-check: off index of contract rows; each row's file:line and probe evidence is in reference/contract-table.md -->
| # | Behaviour | Status | Contract (change-control K#) | If you break it |
|---|---|---|---|---|
| P1 | Subscription window with `date_trunc('millisecond', …)` | MATCH | K8 | events attach to the wrong subscription |
| P2 | `ORDER BY terminated_at DESC NULLS FIRST, started_at DESC` | MATCH | K8 | wrong sub on upgrade/downgrade boundaries |
| P3 | Cache mode skips ms truncation | DIVERGE-VERIFIED | K9 | memory-cache mode only (OD-1) |
| P4 | `utils.ToTime` float math: 496/1000 ms strings land 1 ms early | DIVERGE-VERIFIED | K2 | boundary-ms events miss their sub |
| P5 | RFC3339 timestamps: offset kept, not truncated; CH raw MV rejects them | DIVERGE-VERIFIED | K2 | wrong sub by the offset (DB mode) |
| P6 | No `status` filter in Go; Rails PostProcess excludes `incomplete` | DIVERGE-VERIFIED | K8 | refresh / in-advance for incomplete subs |
| P7 | Recurring fallback: Go window at now(), Rails `.active` | DIVERGE-VERIFIED | K8 | backdated events on non-active subs |
| P8 | BM lookup on kept rows | MATCH | K8 | deleted BMs billed again |
| P9 | count → `"1"`, else `properties[field_name]` | MATCH | K4 | wrong quantity |
| P10 | `value` = Go `%v`: `1000000→"1e+06"`, missing → `"<nil>"` | DIVERGE-VERIFIED | K4 | feeds P11/P12 |
| P11 | `Decimal(38,26)`: values with \|x\| ≥ 1e12 and `"<nil>"` become 0 | DIVERGE-VERIFIED | K4 | silent zero billing (OD-3) |
| P12 | unique_count compares raw `value` strings | DIVERGE-VERIFIED | K4 | double-counted uniques, `"<nil>"` counted |
| P13 | CH `properties` map text ≠ `value` text in the same row | DIVERGE-VERIFIED | K4 | never compare them as strings |
| P14 | lago-expression core source identical (Go v0.2.0, Rails gem `2abd2b3`); `Cargo.lock` crate versions differ | MATCH (source) / UNVERIFIED (behaviour) | — (N3 pins) | different formula results |
| P15 | `event.timestamp`: Go float with ms, Rails integer seconds | DIVERGE-VERIFIED | — | value depends on ingestion path |
| P16 | `properties: null` + expression → Go DLQ | DIVERGE-VERIFIED | — | non-Rails producers must send `{}` |
| P17 | Go evaluates expressions only if `source != "http_ruby"` | MATCH | K3 | double evaluation |
| P18 | `api_post_processed = !clickhouse_events_store?`: one side post-processes | MATCH | K3 | double or missing side effects |
| P19 | In-advance pre-filter: any non-deleted `pay_in_advance` charge | MATCH | K5 | missing in-advance fees |
| P20 | Redis `subscription_refreshed_v2`, `<org>:<sub>\|<bucket>`, 10 s, wall-clock score | MATCH | K1 | wallets/alerts stop refreshing |
| P21 | Rails pops it only if `LAGO_REDIS_STORE_URL` and `LAGO_CLICKHOUSE_ENABLED` are present | INFO | K1 | ZSET grows forever |
| P22 | Rails `timestamp` = `to_f.to_s` / `%s.%3N` | MATCH (parsing); CANDIDATE drift: `Time#to_f.to_s` puts 129/1000 ms values 1 ms early after Go truncation on Ruby 3.3.6 (Ruby 4.0.6 UNVERIFIED; domain-reference MC17) | K2 | parse failures → DLQ |
| P23 | `ingested_at` = `iso8601(3)` minus `Z`; DLQ re-marshal drops ms | MATCH / DIVERGE-VERIFIED | K2, K6 | retries disabled, 1970 in CH |
| P24 | Topic env names | MATCH | K2, K4-K6 | data to nowhere |
| P25 | Keys: Go `<org>-<transaction_id>`, Rails raw none, DLQ none | MATCH | K2, K4, K5 | — (no consumer reads keys) |
| P26 | Enriched JSON covers every CH queue column | MATCH | K4 | CH column silently empty |
| P27 | In-advance JSON vs `Events::CommonFactory` (no `id`) | MATCH | K5 | Rails treats it as API-origin |
| P28 | DLQ JSON vs CH DLQ MV | MATCH / DIVERGE-VERIFIED | K6 | wrong DLQ timestamps |
| P29 | Go drops `external_customer_id` (always null from the API at the pin), ignores `reprocess` | DIVERGE-CODE | K2, K6 | absent downstream |
| P30 | Connector numeric `precise_total_amount_cents` → unmarshal error, no DLQ | DIVERGE-VERIFIED | K2 | silent loss |
| P31-P34 | Charge-filter choice, charge-usage key, expanded/reprocess, refresh v1 | HISTORICAL | — (P34: K1) | do not re-fight (change-control N8) |
<!-- evidence-check: on -->

## 3. Payload schemas

Field-by-field tables for the raw event (Rails, re-enrichment, connectors), the enriched event vs the
ClickHouse `events_enriched` queue/MV/table, the charged-in-advance event vs `Events::CommonFactory`,
the dead-letter payload vs the ClickHouse DLQ MV, and the Redis member: `reference/payload-schemas.md`.
The four facts people get wrong most:
1. Go drops `external_customer_id` (`events-processor/models/event.go:12-23`), which the Rails API always sends as
   null at the pin (`$API/app/controllers/api/v1/events_controller.rb:172-196` does not permit it), so nothing is lost
   from API events; the DLQ `event` is a re-marshalled Go struct, not the original bytes
   (`events-processor/processors/events_processor/event_producer_service.go:52-53`).
2. ClickHouse skips unknown JSON fields, so a renamed Go tag empties a column without any error
   (`.claude/skills/diagnostics-and-tooling/scripts/ch-local.sh "SELECT value FROM system.settings WHERE name='input_format_skip_unknown_fields'" </dev/null` → `1`;
   `.claude/skills/rails-go-parity/scripts/ch-decimal-probe.sh` section E parses a Go payload with extra fields).
3. Rails sends no Kafka key on the raw topic (`$API/app/services/events/kafka_producer_service.rb:29-34`); Go keys
   enriched/in-advance by `<org>-<transaction_id>` (`events-processor/processors/events_processor/event_producer_service.go:30,41`).
4. A JSON integer `ingested_at` (`connectors/http.yml:31`) lands in ClickHouse `events_raw` as 1970-01-21 (read as ms;
   `.claude/skills/rails-go-parity/scripts/ch-decimal-probe.sh | grep 'ingested_at JSON 1741007010 '`).

## 4. Runbook: parity check before merging a C3 or C4 change

Run from the repo root (`cd "$(git rev-parse --show-toplevel)"`). The probes compile against YOUR working
tree (the probe module `replace`s onto `../../../../events-processor`), so they test the change itself.

1. Classify the change with `change-control` (C3 = events-processor behaviour, C4 = delivery or cross-repo contract;
   its C3/C4 precedence rule settles edge cases). `utils/time.go` parsing is C3, C4 if the enriched `timestamp`
   payload format changes.
2. List the rows you touch: `git diff --name-only origin/main...HEAD -- events-processor` (committed) plus
   `git status --short events-processor` (uncommitted), and map files with this table.
   <!-- evidence-check: off routing table (file -> contract rows), not claims -->

   | File touched | Rows to re-check |
   |---|---|
   | `models/subscriptions.go`, `cache/subscriptions.go` | P1-P7 |
   | `utils/time.go` | P4, P5, P22, P23 |
   | `processors/events_processor/enrichment_service.go` | P7, P9, P10, P15-P17, P19 |
   | `models/event.go` | P18, P25-P30 (every JSON tag is contract) |
   | `processors/events_processor/event_producer_service.go`, `processor.go` | P18, P19, P23, P25-P28 |
   | `models/stores.go`, `subscription_refresh_service.go`, `processors/main_processor.go` | P20, P21, P24 |
   | `models/charges.go`, `cache/charges.go` | P19 |
   | `models/billable_metrics.go` | P8, enum line `AGG` |
   | `Dockerfile*`, `.github/workflows/events-processor-tests.yml`, `go.mod` (expression) | P14 |
   <!-- evidence-check: on -->

3. Static guard: `.claude/skills/rails-go-parity/scripts/parity-constants.sh -q`.
   Expected today: `summary: OK=27 KNOWN=12 INFO=4 FAIL=0 CHANGED=0`, exit 0 (add `--network` for P14:
   `OK=28 KNOWN=13`; needs GitHub access, caches a lago-expression clone under `$LAGO_SKILLS_CACHE`).
   `FAIL` = a MATCH row broke: stop. `CHANGED` = a documented divergence moved: update the row.
4. Behaviour probes, compared with the EXPECTED output in section 6:
   ```bash
   .claude/skills/rails-go-parity/scripts/run-probe.sh time
   .claude/skills/rails-go-parity/scripts/run-probe.sh value          # sources ep-env.sh for CGO (cold: ~1 min build)
   .claude/skills/rails-go-parity/scripts/run-probe.sh subscription   # needs Postgres (DATABASE_URL)
   .claude/skills/rails-go-parity/scripts/ch-decimal-probe.sh         # ~210 MB download on first run
   ```
   Any line that differs from EXPECTED is a behaviour change. It is fine only if intended and written into
   `reference/contract-table.md` in the same PR.
5. If a MATCH row, a payload field, the `value` string format (P10-P13), a topic, or the Redis protocol changes
   (in either direction, including closing a DIVERGE row): it is cross-repo (change-control N6; a `value` change in
   `enrichment_service.go` is C3 + C4, a ClickHouse schema part needs OD-3). Open the paired lago-api PR (OPEN DECISION
   OD-4 (owner), default YES), version the key/topic, write the deploy order, and run the guard against the
   paired branch: `.claude/skills/rails-go-parity/scripts/parity-constants.sh --api <dir of the lago-api branch>`.
   The K# column of section 2 names the contract.
6. If the change closes or widens a DIVERGE row: update that row and the EXPECTED block here, and
   reference the `event-accounting-campaign` workstream (W2 value: P10-P13 and P30, which its accounting-probe
   ledger case 5 measures; W3 time: P3-P5, P23; W4 parity harness: P1-P7). Closing a value row (P10-P13) is
   also step 5.
7. Paste the commands and their summary lines in the PR body (change-control N13), next to the output of
   change-control's "Pre-PR gate for events-processor code" block (N9).

## 5. If you see X, do Y

| You see | Likely row | Do |
|---|---|---|
| Sum billed 0 for large numbers on a CH-store org | P11 | Check whether the property has \|x\| ≥ 1e12: `ch-decimal-probe.sh` section D. Do not change the CH schema here (OD-3) |
| unique_count higher than distinct business values | P12, P10 | Look for `"1e+06"` vs `"1000000"` or `"<nil>"` in `events_enriched.value` (compared raw: `$API/app/services/events/stores/clickhouse/unique_count_query.rb:311`) |
| `value` is `"<nil>"` | P10 | Property missing or `null` (`events-processor/processors/events_processor/enrichment_service.go:114`); PG enrich would store 0 (`$API/app/services/events/enrich_service.rb:59`) |
| Event enriched with `subscription_id:""` but Rails bills it | P3, P4, P5 | Run `run-probe.sh subscription`; check ms boundary and timestamp form |
| In-advance fee or refresh for an `incomplete` subscription | P6 | Expected today (DIVERGE); route to `event-accounting-campaign` |
| Wallet / alert refresh never happens for CH-store orgs | P20, P21 | `parity-constants.sh` lines `P20a`-`P20e`, `P21`; check Rails env gating (`$API/clock.rb:210`) |
| Expression result differs between API and connector events | P15 | `event.timestamp` precision differs (`$API/app/services/events/calculate_expression_service.rb:22` passes `to_i`); avoid it in expressions or fix both sides together |
| DLQ row timestamp equals its ingested_at | P28, P5 | RFC3339 timestamp from a non-Rails producer (MV fallback `$API/db/clickhouse_migrate/20260430075848_update_events_dead_letter_mv.rb:13-19`) |
| Connector events vanish, Sentry shows `cannot unmarshal number … precise_total_amount_cents` | P30 | Silent loss (unmarshal error, record committed, no DLQ). Direct producers can send it as a string; through `connectors/*.yml` there is no value-preserving workaround: numbers pass through (Go fails) and anything else, strings included, becomes `"0"` (`connectors/http.yml:32-36`). Fix: `event-accounting-campaign` W2 (Phase 2 item 3) |
| Rails code mentions `events_enriched_expanded` / `reprocess` | P33 | Read `reference/pinned-sha-drift.md`; OD-8 |
| You want Go to pick charge filters or expire Rails cache again | P31, P32 | Don't (change-control N8) |

## 6. Scripts

All read-only on the repo; temp files go to `mktemp -d`, downloads to `${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}`.

| Script | Purpose | Example | Exit codes |
|---|---|---|---|
| `scripts/parity-constants.sh` | Static cross-repo guard: ZSET name, bucket, member/score shape, `http_ruby`, `api_post_processed`, aggregation enum, window SQL, ORDER BY, keys, topic env names, payload field coverage, drift markers | `parity-constants.sh [-q] [--network] [--api DIR] [--ep DIR]` | 0 ok; 1 FAIL; 3 CHANGED; 2 usage/missing file |
| `scripts/run-probe.sh` | Builds a Go probe into a temp dir with a temp `-modfile` (never writes go.mod/go.sum or binaries in the repo) and runs it | `run-probe.sh time\|value\|subscription [args]` | probe's own; 2 usage, `go` missing, or build failure |
| `scripts/time-precision-probe/` | `utils.ToTime`/`ToFloat64Timestamp`/`CustomTime` over `"<s>.<ms>"` ms 0..999 | `run-probe.sh time [-base N] [-scan N] [-fail-on-mismatch]` | 0; 1 with `-fail-on-mismatch` and mismatches > 0; 2 bad flag or unparsable corpus string |
| `scripts/value-format-probe/` | Real `EnrichEvent` `value` for a golden corpus; expression and wire samples (CGO) | `run-probe.sh value [-values-only]` | 0; 1 setup error |
| `scripts/subscription-parity-probe/` | Go DB vs Go cache vs Rails SQL on a throwaway PG database (dropped on exit, also after a setup error) | `DATABASE_URL=… run-probe.sh subscription` | 0 (divergences are data); 1 setup error |
| `scripts/ch-decimal-probe.sh` | clickhouse-local checks for `decimal_value`, queue/MV parsing, DLQ MV, raw MV; binary in the shared cache layout `clickhouse/<ver>/clickhouse` (owner: diagnostics-and-tooling `ch-local.sh`) | `ch-decimal-probe.sh [--version V] [--bin PATH] [-]` | 0 all EXPECTED; 1 mismatch; 2 setup |

EXPECTED output (recorded 2026-10-01 at events-processor `5308258` with Postgres 16 and ClickHouse 26.2.9.9):

`run-probe.sh time`
```
base=1741007009 (2025-03-03T13:03:29Z), corpus=1000 strings "<base>.<ms>" ms=0..999
ToTime(string) mismatches: 496/1000 (exactly 1 ms early: 496)
ToFloat64Timestamp(string) JSON text != input at ms precision: 0/1000
ToTime(float64 JSON number) mismatches: 496/1000
first ToTime mismatches: 1741007009.001 -> 13:03:29.000Z; 1741007009.004 -> 13:03:29.003Z; 1741007009.007 -> 13:03:29.006Z
ToTime("2025-03-03T15:03:29.123456+02:00") = 2025-03-03T15:03:29.123456+02:00 | utc_offset_s=7200 | sub-ms_ns=456000 (numeric branches return UTC, ms-truncated)
ingested_at "2025-03-03T13:03:30.456" -> parsed 2025-03-03T13:03:30.456Z -> re-marshalled (DLQ) "2025-03-03T13:03:30"
missing ingested_at -> zero time; re-marshalled (DLQ) null; time.Since(zero) > 12h = true
```
(`-base` 1000000000, 1073741824, 1700000000, 2147483648 and `-scan 20` all give 496.)

`run-probe.sh value` (condensed from its `go_value` column; full table and wire samples in `reference/payload-schemas.md`)
```
999999 -> "999999"        1000000 -> "1e+06"         12345678 -> "1.2345678e+07"   1e20 -> "1e+20"
1e21 -> "1e+21"           0.1 -> "0.1"               1e-7 -> "1e-07"               2^53+1 -> "9.007199254740992e+15"
null -> "<nil>"           missing -> "<nil>"         true -> "true"                "12" -> "12"
"1000000" -> "1000000"    2.0 -> "2"                 1234567.5 -> "1.2345675e+06"  {"x":1} -> "map[x:1]"
unique_count: number 1000000 -> "1e+06" ; string "1000000" (re-enrichment form) -> "1000000" ; same unique in CH: false
expression event.timestamp (source!=http_ruby, ts "1741007009.123") -> value "1741007009.123" (Rails Lago::Event gets 1741007009)
expression with properties:null (source!=http_ruby) -> error_code="evaluate_expression" failed=true
connector payload with numeric precise_total_amount_cents -> unmarshal error: json: cannot unmarshal number into Go struct field Event.precise_total_amount_cents of type string
```

`run-probe.sh subscription` (scratch database `rgp_probe_<pid>` created and dropped; columns aligned, note column omitted)
```
scenario              go_time             go_db  go_cache  rails_pp  rails_cm  verdict
A sub-ms started_at   13:03:29.000Z       a1     none      a1        a1        DIVERGE(cache!=rails,db!=cache)
B float ms rounding   13:03:29.122Z       none   none      b1        b1        DIVERGE(db!=rails,cache!=rails)
C RFC3339 offset      12:30:00.000+02:00  c1     none      none      none      DIVERGE(db!=rails,db!=cache)
D incomplete status   13:03:29.000Z       d1     d1        none      d1        DIVERGE(db!=rails,cache!=rails)
E overlap tie at T    13:03:29.000Z       e2     e2        e2        e2        MATCH
F recurring fallback  00:00:00.000Z       d1     d1        none      none      DIVERGE(db!=rails,cache!=rails)
```

`ch-decimal-probe.sh`: 39 checks (sections D, E, L, R), `summary: mismatches=0`, exit 0 (same on 25.8.9.20 LTS with
`--version 25.8.9.20`; that release is only published under the `-lts` tag, which the script falls back to; same on
26.2.19.43, the patch `ch-local.sh` cached on 2026-10-01: reuse it with
`--bin "$(.claude/skills/diagnostics-and-tooling/scripts/ch-local.sh --path)"` to avoid a second download). Pipe Go values in with
`run-probe.sh value -values-only | ch-decimal-probe.sh -` (extra `D+` lines, not asserted).

`parity-constants.sh`: `summary: OK=27 KNOWN=12 INFO=4 FAIL=0 CHANGED=0`; with `--network`:
`summary: OK=28 KNOWN=13 INFO=4 FAIL=0 CHANGED=0` (new lines `OK P14n` core source identical, `KNOWN P14d` Cargo.lock
crates differ: pest 2.7.13 vs 2.8.5, bigdecimal 0.4.6 vs 0.4.10, serde_json 1.0.132 vs 1.0.149).

## 7. Divergences are documented here, fixed elsewhere

- Fixes, option menus and acceptance numbers live in `event-accounting-campaign` (target: "the golden
  corpus matches Rails/PG semantics, or each divergence has an owner-approved exception"; "0/1000 ms
  mismatches in `utils.ToTime`"). These are TARGETS, not current state.
- Open decisions this skill touches, all routed through `change-control`:
  OPEN DECISION OD-1 (owner): is memory-cache mode used in production (P3, P7, P19 cache notes);
  OPEN DECISION OD-3 (owner): ClickHouse schema change for `decimal_value` (P11);
  OPEN DECISION OD-4 (owner): paired lago-api PR for contract changes (default YES);
  OPEN DECISION OD-8 (owner): production state of `pre_filter_events`, `lazy_charge_usage_cache`,
  `enriched_events_aggregation` (pinned-SHA drift DR2-DR7).
<!-- evidence-check: off maintenance instruction, not a claim -->
- When a fix lands, flip the row's status, update the EXPECTED block above, and keep the old behaviour in
  the row text so readers of older data understand it.
<!-- evidence-check: on -->

## Provenance and maintenance

- Sources: `events-processor/models/{event,subscriptions,stores,charges,billable_metrics}.go`,
  `events-processor/utils/time.go`, `events-processor/cache/{subscriptions,charges}.go`,
  `events-processor/processors/events_processor/{enrichment_service,processor,event_producer_service,subscription_refresh_service}.go`,
  `events-processor/processors/main_processor.go`, `connectors/*.yml`; `$API/app/services/events/{kafka_producer_service,post_process_service,pay_in_advance_service,calculate_expression_service,create_service,enrich_service,common_factory}.rb`,
  `$API/app/models/events/common.rb`, `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb`,
  `$API/clock.rb`, `$API/karafka.rb`, `$API/db/clickhouse_migrate/*events_{raw,enriched,dead_letter}*`;
  commits `4100da0` (origin of the `%v` value), `d9c32b6`, `2fd8e8b`, `0b56915`, `42615c9`, `fb6401d`, `7421650`, `731e18f`,
  `76c1b3b`, `8ceca4b`;
  getlago/lago-expression `v0.2.0`, `2abd2b3`, `0ff1b8d` (Cargo.lock bump).
- Volatile facts and one-line re-verification (as of 2026-10-01). Set up once from the repo root:
  `S=.claude/skills/rails-go-parity/scripts; API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api); H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`
  - pin: `git ls-tree HEAD api` → `591ae9005110…`; `git -C "$API" log -1 --format='%h %cs'` → `591ae90 2026-09-08`
  - Go HEAD for events-processor: `git log -1 --format='%h %cs' -- events-processor` → `5308258 2026-09-18`;
    `git rev-parse 5308258:events-processor` → `83e012866f29…`
  - Go commits after the pin: `git -C "$H" log --oneline ba292b6..5308258 -- events-processor` → 7 commits incl. `2fd8e8b`, `d9c32b6`
  - all MATCH/KNOWN rows: `$S/parity-constants.sh -q` → `summary: OK=27 KNOWN=12 INFO=4 FAIL=0 CHANGED=0`
  - ToTime precision: `$S/run-probe.sh time | sed -n 2p` → `ToTime(string) mismatches: 496/1000 …`
  - value strings: `$S/run-probe.sh value -values-only 2>/dev/null | head -2` → `999999`, `1e+06`
  - CH decimal cap: `$S/ch-decimal-probe.sh | grep "'1000000000000'"` → `D  '1000000000000'  0  0  ok` (fields are tab-separated)
  - Ruby float timestamp (P22 CANDIDATE, needs `ruby`): `ruby -rbigdecimal -e 'p Time.at(BigDecimal("1727787600.123")).to_f.to_s'`
    → `"1727787600.1230001"` on Ruby 3.3.6 (lago-api pins Ruby 4.0.6: `grep -n '^ruby' "$API/Gemfile"` → `6:ruby "4.0.6"`)
  - expression core: `$S/parity-constants.sh --network | grep -E ' P14[nd] '` → `OK P14n expression-core identical between v0.2.0 and 2abd2b3 …` and
    `KNOWN P14d expression-core deps differ in Cargo.lock: v0.2.0 bigdecimal=0.4.6 pest=2.7.13 serde_json=1.0.132 vs 2abd2b3 …`
  - dev CH image: `grep -n 'image: clickhouse/clickhouse-server' docker-compose.dev.yml` → `460:    image: clickhouse/clickhouse-server:26.2-alpine`
    (`26.2-alpine` floats across 26.2 patch releases; the probe default is the fixed patch `26.2.9.9`)
- Update triggers: an `api` gitlink bump (release); any change to the files listed in step 2 of the runbook;
  a lago-expression ref bump on either side; a ClickHouse version bump (re-run `ch-decimal-probe.sh --version`);
  a new raw-topic producer; lago-api removing `events_enriched_expanded` or `reprocess`; an owner answer to
  OD-1, OD-3, OD-4 or OD-8.
- Probe module upkeep: `scripts/go.mod` replaces onto `../../../../events-processor`; `run-probe.sh` absorbs
  dependency bumps in a temp copy. Refresh `scripts/go.sum` only when it drifts far:
  `cd .claude/skills/rails-go-parity/scripts && go mod tidy` (C0 change).
