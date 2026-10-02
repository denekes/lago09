# W2 value fidelity and W3 time semantics: corpus, derivations, candidate designs, ClickHouse migration track

Read when you work on Phase 2 (including the ClickHouse schema change, s.6) or Phase 3, change `corpus.tsv`, or need to argue what "faithful" means
for a `value` string or a timestamp. Code facts as of 5308258 (events-processor tree 83e012866f29); the
working branch may carry skills-only commits on top; lago-api at the pin `591ae90` (2026-09-08, `$API`).
Verified 2026-10-01 with Ruby 3.3.6, ClickHouse 26.2.9.9 and 26.2.19.43; s.6 (ClickHouse migration track,
DECIDED OD-3 (owner, 2026-10-02)) verified 2026-10-02 with ClickHouse 26.2.19.43 and PostgreSQL 16.14; s.3 kit
evidence (`events-processor-spec` vectors, cited by id) added 2026-10-02.

## 1. How a property becomes billed quantity (today)

| Step | Where | What happens |
|---|---|---|
| decode | `events-processor/processors/events_processor/processor.go:50`, `events-processor/models/event.go:17` | `json.Unmarshal` into `map[string]any`: every JSON number becomes `float64` (no `UseNumber`) |
| format | `events-processor/processors/events_processor/enrichment_service.go:111-116` | count -> `"1"`; else `fmt.Sprintf("%v", properties[field_name])` (`:114`) |
| store (CH) | `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`, cloud copy `$API/db/clickhouse_migrate/cloud/02_events_enriched.sql:12` | `decimal_value Decimal(38,26) DEFAULT toDecimal128OrZero(value, 26)`: 12 integer digits; anything unparsable or out of range becomes 0 |
| aggregate (CH) | `$API/app/services/events/stores/clickhouse_store.rb:190,203,226,416` | sum/max/latest read `decimal_value`; unique_count reads the raw `value` string (`$API/app/services/events/stores/clickhouse/unique_count_query.rb:311`) |
| Rails' own enrichment | `$API/app/services/events/enrich_service.rb:59-60,65,81-85` | `value = properties[field] || 0`; `decimal_value = BigDecimal(value.to_s) rescue 0` |
| PG-store aggregation | `$API/app/services/events/stores/postgres_store.rb:16-19,521-523` | events whose property text does not match `^-?\d+(\.\d+)?$` are excluded |
| Rails -> raw topic | `$API/app/services/events/kafka_producer_service.rb:31-32,36-54` | `properties` re-serialised by Ruby (`Float#to_s`: `1.0e+21`, `1.0e-07`; Integers exact) |

`want_value` / `want_decimal` in `scripts/value-corpus/corpus.tsv` follow Rails' own enrichment (row
"Rails' own enrichment"). `value-corpus -ruby` recomputes them with Ruby's `json` + `bigdecimal`
(`scripts/value-corpus/rails_semantics.rb`): 27/27 rows agree (2026-10-01). The ClickHouse column is an
emulation (`|x| >= 1e12 -> 0`, unparsable -> 0); `-ch-bin` cross-checks it against a real binary: 27/27 on
26.2.9.9 and on 26.2.19.43.

## 2. Expected-today corpus output (Phase-0 numbers)

```
$ .claude/skills/event-accounting-campaign/scripts/run.sh value-corpus -ruby -ch-bin "$(.claude/skills/diagnostics-and-tooling/scripts/ch-local.sh --path)"
id                 json                   go_value                 want_value               ch_decimal(emul)         want_decimal             verdict
int_1e6            1000000                1e+06                    1000000                  1000000                  1000000                  FORMAT
int_1e12_minus_1   999999999999           9.99999999999e+11        999999999999             999999999999             999999999999             FORMAT
int_1e12           1000000000000          1e+12                    1000000000000            0                        1000000000000            FORMAT+CH_ZERO
int_2p53_plus_1    9007199254740993       9.007199254740992e+15    9007199254740993         0                        9007199254740993         PRECISION+CH_ZERO
int_20_digits      12345678901234567890   1.2345678901234567e+19   12345678901234567890     0                        12345678901234567890     PRECISION+CH_ZERO
exp_1e21           1e21                   1e+21                    1000000000000000000000   0                        1000000000000000000000   FORMAT+CH_ZERO
dec_1e-7           0.0000001              1e-07                    0.0000001                0.0000001                0.0000001                FORMAT
neg_1e12           -1000000000000         -1e+12                   -1000000000000           0                        -1000000000000           FORMAT+CH_ZERO
str_1e12           "1000000000000"        1000000000000            1000000000000            0                        1000000000000            CH_ZERO
null               null                   <nil>                    0                        0                        0                        NIL
missing            MISSING                <nil>                    0                        0                        0                        NIL
dec_18_sig         0.123456789012345678   0.12345678901234568      0.12345678901234568      0.12345678901234568      0.12345678901234568      OK
...(27 rows: 13 OK, 14 with a verdict; full table: run the command)
unique_count pair: number 1000000 -> "1e+06", string "1000000" -> "1000000", same unique: false (want true)
ruby cross-check of want columns: 27/27 rows agree
ch cross-check (toDecimal128OrZero(v, 26) on ClickHouse 26.2.19.43): 27/27 values agree with the emulation
...(time section: see s.3)
SUMMARY corpus_rows=27 value_mismatches=13 go_decimal_mismatches=2 ch_zeroed=4 end_to_end_decimal_mismatches=6 totime_mismatches=496/1000 rfc3339_utc_ms=false
```

The `ch cross-check` line names the version `ch-local.sh --path` resolved (whatever the cache holds;
26.2.19.43 here). Verdicts: FORMAT = string differs, number equal (breaks unique_count only); NIL = Go
writes `"<nil>"` where Rails uses 0; PRECISION = float64 lost digits (> 2^53); CH_ZERO = ClickHouse stores 0
for a value Rails keeps. SUMMARY counters: `ch_zeroed` = rows whose Go string is numerically exact but
ClickHouse stores 0 (zeroed by the column alone); `end_to_end_decimal_mismatches` = rows whose stored
decimal differs from Rails' for any reason (today: the 4 `ch_zeroed` rows + the 2 PRECISION rows).
Readings that matter:
- 2 rows are wrong in Go itself (PRECISION, `int_2p53_plus_1` and `int_20_digits`; float64 decode at `events-processor/models/event.go:17`): fixable in Go alone (W2).
- 4 more rows are zeroed only by `Decimal(38,26)` (`int_1e12`, `exp_1e21`, `neg_1e12`, `str_1e12`): their
  Go string is numerically exact (`1e+12` = 1000000000000; only `str_1e12` is also textually equal), yet they
  are billed 0, as a perfect string would be. Go alone cannot fix that: the ClickHouse column must change,
  which DECIDED OD-3 (owner, 2026-10-02) allows. The CANDIDATE column of s.6 stores all of them exactly
  (`ch-schema-candidate.sh`: `cand_mismatches=0`).
- `dec_18_sig` matches because Rails also parses JSON floats into `Float` (Ruby cross-check of that row,
  `.claude/skills/event-accounting-campaign/scripts/run.sh value-corpus -ruby`): the contract for non-integers is
  "shortest round-trip float", not "the literal text". Only integers (Ruby `Integer` is exact) need `json.Number`.

## 3. Time today (W3)

```
ToTime("1741007009.<ms>") ms=0..999: 496/1000 land on a different millisecond; first: 1741007009.001 -> 13:03:29.000Z; ...
ToTime("2025-03-03T15:03:29.123456+02:00") = 2025-03-03T15:03:29.123456+02:00 (utc_offset_s=7200, sub-ms ns=456000) -> normalised to UTC+ms: false
```
- Cause: `events-processor/utils/time.go:20-23` computes nanoseconds as `int64((f - float64(sec)) * 1e9)`
  and `:48` truncates to ms, so `.123` -> `0.12299990654` s -> `.122`. The RFC3339 branch (`:25-29`) returns
  before the UTC + ms normalisation at `:48`.
- Only the subscription-lookup time (`EnrichedEvent.Time`, `events-processor/models/event.go:77-81`) uses
  `ToTime`; the emitted `timestamp` uses `ToFloat64Timestamp` (`time.go:51-78`), whose string branch
  truncates correctly (rails-go-parity measures 0/1000 there).
- Rails sends `timestamp: event.timestamp.to_f.to_s` (`$API/app/services/events/kafka_producer_service.rb:43`;
  that string itself lands 129/1000 ms values of epoch second 1727787600 1 ms early after
  millisecond truncation, identically on Ruby 3.3.6 and the pinned Ruby 4.0.6 (EXECUTED 2026-10-02 with the
  kit oracle's Ruby; `rails-go-parity` P22, `domain-reference` MC17)
  and matches subscriptions with `date_trunc('millisecond', started_at) <= ts`
  (`$API/app/services/events/post_process_service.rb:50-53`); Go DB mode uses the same SQL
  (`events-processor/models/subscriptions.go:29-34`). So a 1 ms-early `ToTime` only matters at a window
  boundary: an event in the `started_at` millisecond misses its subscription (measured by `rails-go-parity`,
  its sub-probe B), and an event in the millisecond right after `terminated_at` is still attached to the
  terminated subscription, in both modes: EXECUTED 2026-10-02 by the re-implementation kit
  (`events-processor-spec` vectors ep.match_subscription.003 (DB) and .004 (cache): `"1748736000.001"` with
  `terminated_at` `…00.0007` matches). Boundary-parity scenarios (DB vs cache vs Rails SQL) are
  measured by `rails-go-parity` (its subscription probe); this skill only counts `ToTime`.
- Mode deltas the W3 change must keep in mind (EXECUTED by the same kit vectors; table:
  `architecture-contract` memory-cache.md §1a): an RFC 3339 offset is compared as the wall clock of that offset
  in DB mode and as an instant in cache mode (ep.match_subscription.016 / .017:
  `"2025-03-01T00:30:00+01:00"` picks the new subscription in DB mode, the old one in cache mode); `started_at` is
  compared at ms in DB mode and at µs in cache mode (ep.match_subscription.009 / .010, W6-4).
- Non-finite and non-decimal spellings: `strconv.ParseFloat` also accepts `"NaN"`, `"Inf"` and hexadecimal floats
  (`events-processor/utils/time.go:20,56`). `"NaN"` / `"Inf"` then fail when the enriched record is marshalled:
  nothing is produced, no DLQ, committed (ledger case 16, SENTRY_ONLY in both modes; kit EPC-08). A hex float such
  as `"0x1.9f0e3a8p+30"` is accepted as seconds (kit EPC-08; whether to reject it is an open kit owner question).

## 4. The UseNumber trap (VERIFIED 2026-10-01)

Decoding the whole event with `json.Decoder.UseNumber()` fixes `properties` but breaks numeric timestamps:
`Event.Timestamp` is `any` (`events-processor/models/event.go:20`) and neither `ToTime` nor
`ToFloat64Timestamp` has a `json.Number` case.
```bash
d=$(mktemp -d) && repo=$(git rev-parse --show-toplevel) && cd "$d" && printf 'module t\n\ngo 1.25.0\n\nrequire github.com/getlago/lago/events-processor v0.0.0\n\nreplace github.com/getlago/lago/events-processor => %s/events-processor\n' "$repo" > go.mod && cat > main.go <<'EOF'
package main

import (
	"bytes"
	"encoding/json"
	"fmt"

	"github.com/getlago/lago/events-processor/models"
)

func main() {
	var e models.Event
	d := json.NewDecoder(bytes.NewReader([]byte(`{"timestamp":1609459200,"properties":{"amount":9007199254740993}}`)))
	d.UseNumber()
	_ = d.Decode(&e)
	r := e.ToEnrichedEvent()
	fmt.Println(r.Failure(), r.Error(), e.Properties["amount"])
}
EOF
GOFLAGS=-mod=mod go run . 2>/dev/null; cd - >/dev/null; rm -rf "$d"
# expect: true Unsupported timestamp type: json.Number 9007199254740993
```
Connectors send numeric timestamps (`connectors/sqs.yml:74`, `connectors/README.md:13-14`), so a global
`UseNumber` would turn every connector event into a `build_enriched_event` DLQ entry. Decode numbers
exactly only inside `properties`, or add `json.Number` cases to both time functions in the same change.

## 5. Candidate designs (CANDIDATE: none is implemented or approved)

W2 value (Phase 2):
1. Decode `properties` with `UseNumber` (custom `UnmarshalJSON` on the properties map, or a second decode
   pass) and format: `json.Number` integer text -> as is; non-integer -> parse as float64, then
   `strconv.FormatFloat(f, 'f', -1, 64)` (shortest round-trip, plain decimal, same as Ruby `Float`);
   `float64` (expression results) -> same; `nil` -> `"0"` (`enrich_service.rb:59`); `string` -> as is;
   bool/object/array -> keep today's text (decimal 0 either way) unless the owner wants a DLQ cause.
   Expected corpus result after the change (prediction, not run): value_mismatches 0,
   go_decimal_mismatches 0, ch_zeroed 4 -> 6 (the 2 PRECISION rows become exact but are still >= 1e12),
   end_to_end_decimal_mismatches still 6 until the ClickHouse column of s.6 lands (then 0 for every numeric
   row: `ch-schema-candidate.sh` `cand_mismatches=0`).
2. Overflow policy (DECIDED OD-3 (owner, 2026-10-02): the schema may change): the plan is (c), change the
   CH column (s.6: `Decimal(40,15)`, the Postgres type), so the overflow threshold moves from 1e12 to 1e25.
   What still overflows (|x| >= 1e25, which Postgres `numeric(40,15)` rejects too) is DLQ'd by Go with a new
   cause such as `value_out_of_range`: PERMANENT under ADR-001; a new DLQ cause changes disposition, so C4
   under change-control's precedence rule; no DLQ replay tool exists yet (`delivery-options.md` s.6 step 4e).
   (b) "accept and document" is no longer needed for 1e12..1e25. Never change precision without the corpus
   proof (`scripts/ch-schema-candidate.sh`, s.6.2).
3. `precise_total_amount_cents` (case 5 of the ledger): accept JSON number and string in
   `events-processor/models/event.go:18` (custom type that keeps the decimal text). Changing the JSON tag
   type is C4 in change-control's path table. Also note `connectors/http.yml:32-36` maps every non-number
   (including a string) to `"0"`: a string amount sent to a connector is silently zeroed before Go sees it.
4. Rollout trap: unique_count compares raw strings. Switching `"1e+06"` -> `"1000000"` mid-period makes the
   same business value two uniques until the period closes (old rows keep the old string). Ship at a period
   boundary or accept a one-period overcount; write it in the PR. Inference from
   `unique_count_query.rb:311`; not measured on a live cluster (UNVERIFIED).

W3 time (Phase 3):
1. Parse `"<sec>.<frac>"` without floats (split on `.`, right-pad/truncate the fraction to 3 digits), or
   `math.Round(f*1000)` with a proof over the corpus; target `totime_mismatches=0/1000`.
2. RFC3339 branch: `.UTC().Truncate(time.Millisecond)`; target `rfc3339_utc_ms=true`. This changes which
   subscription matches events sent with an offset (DB mode compares the wall clock today: EXECUTED,
   ep.match_subscription.016; cache mode already compares instants, .017). C3 (C4 if the enriched `timestamp`
   payload format changes); run the rails-go-parity subscription probe and the kit gate EPC-04
   (`ledger-and-matrix.md` s.7) before and after.
3. CANDIDATE: add a `json.Number` case to `ToTime`/`ToFloat64Timestamp` if W2 lands first (section 4).
4. Optional sanity bound on epoch magnitude (`events-processor/utils/time.go:20-23`): `utils.ToTime("1741007009123")` (a ms epoch) succeeds today
   with year 57140 (VERIFIED 2026-10-01 with a scratch module); a new DLQ cause = C4 and an owner call.
5. CANDIDATE: non-finite timestamps (`"NaN"`, `"Inf"`): reject them in both time functions
   (`events-processor/utils/time.go:20,56`) so the record is DLQ'd as
   `build_enriched_event` (PERMANENT under ADR-001; `reimplementation-kit` RBD-4, decided). It changes
   disposition, so C4 under change-control's precedence rule. Gate: ledger case 16 SENTRY_ONLY -> DLQ in both
   modes, kit EPC-08 PASS.

## 6. ClickHouse migration track (Phase 2; DECIDED OD-3 (owner, 2026-10-02); design CANDIDATE)

The owner accepted a ClickHouse schema change on 2026-10-02. Never change precision without the corpus proof
below; the decision allows the change, it does not pick the type.

### 6.1 What changes where (verified 2026-10-02 at the pin)

| Object | Today | Evidence |
|---|---|---|
| self-host `events_enriched.decimal_value` | `Decimal(38,26) DEFAULT toDecimal128OrZero(value, 26)`: 12 integer digits | `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32` |
| self-host `events_enriched_expanded.decimal_value` | same type and default | `$API/db/clickhouse_migrate/20250814090557_create_events_enriched_expanded.rb:36` |
| Cloud DDL, the second schema, edited in place | `Nullable(Decimal(38, 26)) DEFAULT toDecimal128OrZero(value, 26)` in both tables | `$API/db/clickhouse_migrate/cloud/02_events_enriched.sql:12`, `cloud/05_events_enriched_expanded.sql:13`; rule `$API/AGENTS.md:176` (one DDL concern per migration, explicit `up`/`down`: `:177-178`) |
| the MVs feeding them | do not select `decimal_value`: the column DEFAULT computes it at insert | `$API/db/clickhouse_migrate/20240705085501_create_events_enriched_mv.rb:6-15`, `20250814125620_create_events_enriched_expanded_mv.rb:6-23` |
| Postgres store (the alignment target) | `enriched_events.decimal_value numeric(40,15) DEFAULT 0.0 NOT NULL` | `$API/db/structure.sql:3059` |
| precedent in the same CH table | `precise_total_amount_cents Decimal(40,15)` | `20240705080709_create_events_enriched.rb:34`; `cloud/02_events_enriched.sql:13` |
| aggregate states typed on the old decimal | none left: `events_aggregated` was dropped | `$API/db/clickhouse_migrate/20251202134733_drop_events_aggregated.rb` |
| Rails readers | sum/max/latest/weighted read `decimal_value`; the API serializer prints `decimal_value.to_s` | `$API/app/services/events/stores/clickhouse_store.rb:190,203,226,418`; `$API/app/serializers/v1/event_enriched_serializer.rb:13` |
| who writes `events_enriched_expanded` | no producer in this repo or in `$API/app`, `$API/config` (only the queue migration names its topic) | `grep -rn ENRICHED_EVENTS_EXPANDED "$API/app" "$API/config" events-processor` -> no output; `$API/db/clickhouse_migrate/20250814124830_create_events_enriched_expanded_queue.rb:9` |

### 6.2 Candidate column and its proof (VERIFIED 2026-10-02: ClickHouse 26.2.19.43, PostgreSQL 16.14)

<!-- evidence-check: off CANDIDATE design; proof is the ch-schema-candidate.sh output below -->
```sql
decimal_value Nullable(Decimal(40, 15)) DEFAULT
  if(abs(toDecimal256OrNull(value, 18)) < toDecimal256('10000000000000000000000000', 0),
     round(toDecimal256OrNull(value, 18), 15), NULL)
```
Why each part:
- `Decimal(40, 15)` = Postgres `numeric(40,15)`: 25 integer digits instead of 12, so every corpus number
  >= 1e12 fits.
- parse at scale 18, then `round(…, 15)`: ClickHouse truncates extra decimals on parse
  (`toDecimal256OrNull('0.12345678901234568', 15)` -> `0.123456789012345`), Postgres rounds half away from
  zero (`0.123456789012346`); 3 guard digits + `round` give Postgres' result (all 33 rows below agree).
- the explicit `< 1e25` bound: a `Decimal(40, 15)` column does NOT enforce its precision in ClickHouse
  (`clickhouse local` stored `1e30` and `1e60` unchanged; only `1e62` overflowed Decimal256 to NULL), while
  Postgres rejects `'1e25'::numeric(40,15)` with `numeric field overflow`.
- `…OrNull` instead of `…OrZero`: an unparsable or out-of-range value is visible (NULL) instead of
  indistinguishable from a real 0.
<!-- evidence-check: on -->

```
$ .claude/skills/event-accounting-campaign/scripts/ch-schema-candidate.sh -q
SUMMARY corpus_rows=27 edge_rows=6 today_corpus_mismatches=6 cand_mismatches=0 cand_policy_null=3 rederive_needs_re_enrichment=2 rederive_policy_null=3 pg_reference=postgres
```
(~7 s; without `-q` it prints all 33 rows: today, cand, rederive and the Postgres value per row.)
- `today_corpus_mismatches=6` reproduces `end_to_end_decimal_mismatches=6` of `.claude/skills/event-accounting-campaign/scripts/run.sh value-corpus` with a real
  ClickHouse: the old column zeroes every value >= 1e12.
- `cand_mismatches=0`: the candidate column fed with the CANDIDATE Go strings (s.5 W2 item 1) equals
  Postgres `numeric(40,15)` on all 27 corpus rows and 6 edge rows (`1e25` and `-1e25` -> NULL where
  Postgres overflows; `0.0000000000000005` -> `0.000000000000001` on both sides).
- `cand_policy_null=3`: `str_abc`, `bool_true`, `object` become NULL where Rails stores 0. Rails' own
  enrichment says so on purpose ("it will then fall back to 0 … aligned with the Clickhouse implementation
  but differs … from the current PG one where we explicitly filter events with invalid values",
  `$API/app/services/events/enrich_service.rb:62-64`); the PG store drops such rows by regex
  (`$API/app/services/events/stores/postgres_store.rb:521-523`). NULL behaves like that filter in
  `sum`/`max`/`argMax` (they skip NULL). NULL (detectable) vs `ifNull(…, 0)` (today's Rails semantics) is
  decided by lago-api maintainers in the paired PR; missing/null properties are not affected (Go emits `"0"`,
  Rails `|| 0`).
- Precision change to state in the PR: values with more than 15 decimals keep 15 (rounded). Today the CH
  column keeps 26 (`dec_18_sig`: today `0.12345678901234568`, candidate `0.123456789012346` = what PG-store
  orgs already store).
- Rails readers: `sum` over the candidate column returns `Nullable(Decimal(76, 15))` (VERIFIED on
  `clickhouse local`) instead of a Decimal128 type; how lago-api's ClickHouse adapter parses Decimal256
  results is UNVERIFIED: lago-api specs in the paired PR.

### 6.3 Historical rows

`value` (the raw string) is stored, so `decimal_value` can be re-derived by a mutation. The `rederive`
column of the script applies the candidate expression to TODAY's Go strings, with `'<nil>'` mapped to `'0'`
first (Rails `|| 0`): 25 of 27 rows come out right (3 of them NULL under the policy above);
`rederive_needs_re_enrichment=2` are the integers above 2^53 whose Go string already lost digits
(`9.007199254740992e+15`, `1.2345678901234567e+19`). Those need the exact source text:
- re-enrichment through lago-api (`$API/app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb` exists; lago-api work), or
- `events_raw.properties[<field>]`, which keeps the JSON text exactly: the raw MV extracts properties with
  `JSONExtract(properties, 'Map(String, String)')` (`$API/db/clickhouse_migrate/20231030163703_create_events_raw_mv.rb:12`),
  and on `clickhouse local` that turns `9007199254740993` into `'9007199254740993'` and
  `12345678901234567890` into `'12345678901234567890'` (VERIFIED 2026-10-02). A mutation cannot JOIN, so this
  needs a Join-engine table or a dictionary keyed by `(organization_id, transaction_id)` (CANDIDATE).
- Affected rows are findable: a Go float string with an exponent and magnitude >= 2^53, e.g.
  `position(value, 'e+') > 0 AND abs(toFloat64OrZero(value)) >= 9007199254740992` (CANDIDATE predicate).
- `unique_count` reads `value`, not `decimal_value` (`$API/app/services/events/stores/clickhouse/unique_count_query.rb:311`):
  the mutation does not touch it; the Go format change (s.5 item 4) still has its own rollout trap.

### 6.4 Paired lago-api PR and deploy order (DECIDED OD-4 (owner, 2026-10-02): the schema lives in lago-api)

<!-- evidence-check: off CANDIDATE rollout plan; rules from change-control §6, facts in 6.1-6.3 -->
Additive first (`change-control` §6 rule 1; irreversible steps only in cleanup, rule 5):
1. lago-api: add a NEW column (name CANDIDATE, e.g. `decimal_value_v2`) with the candidate type and
   DEFAULT to `events_enriched` and `events_enriched_expanded`, self-host migration + Cloud DDL in the same
   PR (one DDL concern per migration). New rows get both columns. The reader is tolerant by construction:
   the candidate expression parses today's Go strings too (the `rederive` column).
2. Backfill `decimal_value_v2` for historical rows by mutation (6.3), partition by partition; re-enrich
   the > 2^53 rows. Rehearse on a copy of a production-size partition first and record the duration
   (owner/ops: the mutation budget is not visible from here).
3. lago-api readers switch to the new column (store classes, serializer), behind the existing store
   selection; specs pin the Decimal256 result parsing.
4. events-processor: W2 exact strings (s.5 item 1) and a `value_out_of_range` DLQ for |x| >= 1e25
   (PERMANENT under ADR-001; a new DLQ cause is C4). Ordering between 3 and 4 is free: the new column
   reads both string formats.
5. Cleanup a release later: drop the old column (or rename), by lago-api.
An in-place `MODIFY COLUMN` is the alternative: one step, but the cast rewrites data and cannot be rolled
back. Use it only if lago-api maintainers accept that explicitly in the paired PR.
<!-- evidence-check: on -->

### 6.5 What this skill changes when the column lands (C1 to this skill, same PR as step 3)

- `scripts/value-corpus/main.go:117` (`chLimit` = 1e12 for Decimal(38,26)) and the `-ch-bin` cross-check
  (`toDecimal128OrZero(v, 26)`) follow the new column; corpus notes that mention `Decimal(38,26)` are updated.
- `end_to_end_decimal_mismatches` target 0 needs the policy rows settled first: NULL means `want_decimal`
  of `str_abc`, `bool_true`, `object` changes (with an exception marker that `value-corpus` and
  `rails_semantics.rb` both honour: not built, CANDIDATE); `ifNull(…, 0)` keeps them.
- Gates: `ch-schema-candidate.sh` `cand_mismatches=0 pg_reference=postgres` on the final expression;
  `value-corpus -ruby` value metrics at target; `rails-go-parity` value rows (P10-P13) updated.
