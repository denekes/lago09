# W2 value fidelity and W3 time semantics: corpus, derivations, candidate designs

Read when you work on Phase 2 or Phase 3, change `corpus.tsv`, or need to argue what "faithful" means
for a `value` string or a timestamp. Code facts as of 5308258 (events-processor tree 83e012866f29); the
working branch may carry skills-only commits on top; lago-api at the pin `591ae90` (2026-09-08, `$API`).
Verified 2026-10-01 with Ruby 3.3.6, ClickHouse 26.2.9.9 and 26.2.19.43.

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
- 2 rows are wrong in Go itself (PRECISION, `int_2p53_plus_1` and `int_20_digits`): fixable in Go alone (W2).
- 4 more rows are zeroed only by `Decimal(38,26)` (`int_1e12`, `exp_1e21`, `neg_1e12`, `str_1e12`): their
  Go string is numerically exact (`1e+12` = 1000000000000; only `str_1e12` is also textually equal), yet they
  are billed 0, as a perfect string would be. Go cannot fix that without OPEN DECISION OD-3 (owner); Go can detect it and
  DLQ it instead of letting it become 0 (CANDIDATE).
- `dec_18_sig` matches because Rails also parses JSON floats into `Float` (Ruby cross-check of that row): the contract for non-integers is
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
  on Ruby 3.3.6 that string itself lands 129/1000 ms values of epoch second 1727787600 1 ms early after
  millisecond truncation: CANDIDATE drift,
  `rails-go-parity` P22, `domain-reference` MC17; lago-api pins Ruby 4.0.6, UNVERIFIED there)
  and matches subscriptions with `date_trunc('millisecond', started_at) <= ts`
  (`$API/app/services/events/post_process_service.rb:50-53`); Go DB mode uses the same SQL
  (`events-processor/models/subscriptions.go:29-34`). So a 1 ms-early `ToTime` only matters at a window
  boundary: an event in the `started_at` millisecond misses its subscription (measured by `rails-go-parity`,
  its sub-probe B), and, by the same SQL, an event in the millisecond right after `terminated_at` would still
  match (inference, not probed here). Boundary-parity scenarios (DB vs cache vs Rails SQL) are
  measured by `rails-go-parity` (its subscription probe); this skill only counts `ToTime`.

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
   end_to_end_decimal_mismatches still 6 (needs OD-3 or the overflow policy below).
2. Overflow policy (needs an owner answer, routed through change-control; part of OD-3): when the exact
   value has `|x| >= 1e12` or more than 26 decimals, either (a) DLQ with a new cause such as
   `value_out_of_range` (a new DLQ cause changes disposition: C4 under change-control's precedence rule,
   ADR + owner acceptance; DLQ'd rows are not replayable today), or (b) accept and document, or (c) change the CH
   schema (lago-api work, migration budget, `$API/AGENTS.md:176` says cloud DDL in
   `db/clickhouse_migrate/cloud/*.sql` is edited in place). Never (c) without OD-3.
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
   subscription matches events sent with an offset (DB mode compares the wall clock today). C3 (C4 if the
   enriched `timestamp` payload format changes); run the rails-go-parity subscription probe before and after.
3. CANDIDATE: add a `json.Number` case to `ToTime`/`ToFloat64Timestamp` if W2 lands first (section 4).
4. Optional sanity bound on epoch magnitude: `utils.ToTime("1741007009123")` (a ms epoch) succeeds today
   with year 57140 (VERIFIED 2026-10-01 with a scratch module); a new DLQ cause = C4 and an owner call.
