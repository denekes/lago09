# Value corpus: JSON literal → `value` string (compat and corrected)

Part of `events-processor-spec` (re-implementation kit v1.6.0). The `value` string of an enriched record is what
the ClickHouse event store turns into the number it aggregates, so its text is a billing contract. Read when you
implement EP-F2 (`processing-rules.md`) or a downstream reader of `value`. Data file:
`conformance/value-corpus.tsv` (columns id, json, want_value, want_decimal, note); exercised by EPC-07 (through
the whole processor) and `ep.value_string.001-027` (unit vectors).

> **Licence.** The Lago events-processor and lago-api are AGPL-3.0. This chapter states observable behaviour in
> neutral words and tables; it contains no copied source. A clean-room rebuild that will not be AGPL needs legal
> review (`reimplementation-kit` reference/legal-and-provenance.md).

## 1. The table

Metric under test: `api_calls`, sum of `amount`. "Compat" = the reference's `value` (EP-F2 reference rules);
"Corrected" = the corrected profile's `value` (RBD-13, decided); "Billing decimal" = the number the billing
engine derives from the same literal when it parses events itself (for comparison).

<!-- evidence-check: off corpus table; evidence = the vector id in the last column (ep-oracle, reference packages) and EPC-07 -->
| Corpus id | `amount` literal | Compat `value` | Corrected `value` | Billing decimal | Vector |
|---|---|---|---|---|---|
| `int_42` | `42` | `42` | `42` | `42` | ep.value_string.001 |
| `int_999999` | `999999` | `999999` | `999999` | `999999` | ep.value_string.002 |
| `int_1e6` | `1000000` | `1e+06` | `1000000` | `1000000` | ep.value_string.003 |
| `int_12345678` | `12345678` | `1.2345678e+07` | `12345678` | `12345678` | ep.value_string.004 |
| `int_1e12_minus_1` | `999999999999` | `9.99999999999e+11` | `999999999999` | `999999999999` | ep.value_string.005 |
| `int_1e12` | `1000000000000` | `1e+12` | `1000000000000` | `1000000000000` | ep.value_string.006 |
| `int_2p53_plus_1` | `9007199254740993` | `9.007199254740992e+15` | `9007199254740993` | `9007199254740993` | ep.value_string.007 |
| `int_20_digits` | `12345678901234567890` | `1.2345678901234567e+19` | `12345678901234567890` | `12345678901234567890` | ep.value_string.008 |
| `exp_1e21` | `1e21` | `1e+21` | `1000000000000000000000` | `1000000000000000000000` | ep.value_string.009 |
| `dec_0.1` | `0.1` | `0.1` | `0.1` | `0.1` | ep.value_string.010 |
| `dec_0.0001` | `0.0001` | `0.0001` | `0.0001` | `0.0001` | ep.value_string.011 |
| `dec_1e-5` | `0.00001` | `1e-05` | `0.00001` | `0.00001` | ep.value_string.012 |
| `dec_1e-7` | `0.0000001` | `1e-07` | `0.0000001` | `0.0000001` | ep.value_string.013 |
| `dec_1234567.5` | `1234567.5` | `1.2345675e+06` | `1234567.5` | `1234567.5` | ep.value_string.014 |
| `dec_2.0` | `2.0` | `2` | `2` | `2` | ep.value_string.015 |
| `dec_18_sig` | `0.123456789012345678` | `0.12345678901234568` | `0.12345678901234568` | `0.12345678901234568` | ep.value_string.016 |
| `neg_5` | `-5` | `-5` | `-5` | `-5` | ep.value_string.017 |
| `neg_1e12` | `-1000000000000` | `-1e+12` | `-1000000000000` | `-1000000000000` | ep.value_string.018 |
| `str_12` | `"12"` | `12` | `12` | `12` | ep.value_string.019 |
| `str_1000000` | `"1000000"` | `1000000` | `1000000` | `1000000` | ep.value_string.020 |
| `str_1e12` | `"1000000000000"` | `1000000000000` | `1000000000000` | `1000000000000` | ep.value_string.021 |
| `str_exp` | `"1e6"` | `1e6` | `1e6` | `1000000` | ep.value_string.022 |
| `str_abc` | `"abc"` | `abc` | `abc` | `0` | ep.value_string.023 |
| `null` | `null` | `<nil>` | `0` | `0` | ep.value_string.024 |
| `missing` | (key absent) | `<nil>` | `0` | `0` | ep.value_string.025 |
| `bool_true` | `true` | `true` | no contract | `0` | ep.value_string.026 |
| `object` | `{"x":1}` | `map[x:1]` | no contract | `0` | ep.value_string.027 |
<!-- evidence-check: on -->

13 of the 25 graded literals differ between the profiles (all integers of 7 or more digits, magnitudes below
1e-4, `1234567.5`, and the missing / null cases).

## 2. The rules behind the columns

Compat (reference), for a JSON number: take its IEEE-754 binary64 value; write the fewest significant digits
that read back to that value; let `e` be the decimal exponent of the first significant digit (value = d.ddd ×
10^e). If `e < −4` or `e ≥ 6`, write `d.ddd` followed by `e`, a sign and at least two exponent digits (`1e+06`,
`1e-05`); otherwise write plain decimal notation with no trailing zeros and no trailing point. JSON strings are
copied verbatim, booleans as `true`/`false`, missing or null as `<nil>`, objects and arrays in an internal
rendering that no consumer can parse.

Corrected (RBD-13), classified by the JSON literal, not by its value: an integer literal (digits with an
optional minus sign, no fraction, no exponent) is written exactly as its decimal digits at any size (no binary64
rounding); every other number literal (`2.0`, `1e21`, `0.1`) as the shortest round-trip binary64 digits in plain
notation (the billing engine reads such literals as binary64 too, so `0.123456789012345678` → `0.12345678901234568` in both profiles); `"0"` for a
missing key or `null`; strings verbatim. The ClickHouse column that stores the derived decimal must accept the
full range (owner decision OD-3 allows an exact numeric(40,15)-compatible column; RBD-26).

What breaks downstream with compat text: the reference ClickHouse decimal conversion returns 0 for any text it
cannot parse, so `1e+06`, `<nil>` and `map[…]` aggregate as 0, and values of 1e12 or more overflow the reference
decimal column (38 digits, 26 decimals) and also become 0. That is a billing error, not a formatting detail.

## 3. Keeping the corpus in sync

The data rows are shared with the `event-accounting-campaign` skill (its value corpus). Check:
`python3 .claude/skills/events-processor-spec/scripts/gen-scenarios.py --check-corpus .claude/skills/event-accounting-campaign/scripts/value-corpus/corpus.tsv`
→ `corpus-sync: OK rows=27` (2026-10-02). After a change, regenerate EPC-07 (`gen-scenarios.py --write`), its goldens
(`maintainer/regen-goldens.sh --only EPC-07`) and the unit vectors (`maintainer/mint-ep-units.py --write`).

## Provenance (maintainers)

Compat column: ep-oracle (reference packages of events-processor tree `83e012866f29`,
`events-processor/processors/events_processor/enrichment_service.go:114`) via `scripts/maintainer/mint-ep-units.py`,
and EPC-07 goldens (both modes, three passes). Corrected and billing columns: corpus `want_value` / `want_decimal`,
derived from the billing engine's enrichment rule `$API/app/services/events/enrich_service.rb:59` @591ae90
(value = property or 0; decimal = parsed value or 0). Reference ClickHouse conversion:
`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32` @591ae90.
