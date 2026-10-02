# 03 — Expression language (BE-EX)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08)
> and of the expression engine it embeds (also embedded by the Lago events-processor). It is a behavioural
> specification written fresh from executed vectors and probes, not source code. The engine's own licence is not
> stated in its sources (open question KQ-7): re-implement the language from this chapter rather than embedding
> the reference engine. Proprietary clean-room rebuilds should have it reviewed
> (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90` and events-processor tree `83e012866f29`. A billable metric may carry an
**expression**: a small arithmetic/string language evaluated on each event; its result replaces the metric's field
(`properties[field_name]`) before aggregation. The language is evaluated on three **surfaces**, which share the
grammar and the arithmetic but differ in how the event is presented to the engine and how the result is written:

| Surface | Where | Vector `mode` | Result lands in |
|---|---|---|---|
| ingestion | billing API, while accepting an event (chapter 02, BE-EV-50) | `rails` | stored/published event, as decimal text |
| processor | events-processor, for records not produced by the billing API (`events-processor-spec` EP-G1..G3) | `ep` | enriched record, as the engine's text |
| preview | `POST /api/v1/billable_metrics/evaluate_expression` (test an expression) | `preview` | response body |

Reading guide: rules are numbered `BE-EX-n`; every rule line ends with `[vec: …]` naming vectors in
`billing-engine-spec/vectors/expression.jsonl` (op `expression.evaluate`, schema
`reimplementation-kit/schemas/ops/expression.evaluate.schema.json`) or a prose-only marker. The op returns `value`
(a canonical decimal for numbers, the text for strings), `type` (`number` | `string`, not observable on the
processor surface) and `text` (the exact text where the result lands), or the error codes `parse_error`,
`evaluation_error`, and on the preview surface the endpoint's own codes.

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Grammar

Fresh EBNF (tokens may be separated by any number of space characters U+0020; no other whitespace):

```
expression = term , { operator , term } ;
operator   = "+" | "-" | "*" | "/" ;
term       = [ "-" ] , primary ;
primary    = call | variable | decimal | string | "(" , expression , ")" ;
call       = function , "(" , expression , { "," , expression } , ")" ;
function   = ("round" | "ceil" | "floor" | "concat" | "least" | "greatest")      (* lower case, *)
             (* or the same name fully upper case, or capitalised: ROUND, Round *) ;
variable   = "event.code" | "event.timestamp" | "event.properties." , name ;    (* one token, no spaces *)
name       = letter , { letter | digit | "_" } ;                                 (* ASCII *)
decimal    = digit , { digit } , [ "." , digit , { digit } ] ;
string     = "'" , { any character except "'" } , "'" ;
```

- **BE-EX-1** Binary operators `+ - * /`; `*` and `/` bind tighter than `+` and `-`; all are left-associative (`10 - 4 - 3` = 3). There is no power, modulo or comparison operator. [vec: expression.grammar.001, expression.grammar.002, expression.grammar.006]
- **BE-EX-2** A term may carry ONE leading unary minus, applying to its primary only (`-2 * 3` = −6, `2 - -3` = 5, `- 3` = −3); two signs in a row (`- - 3`) do not parse; negate a group with `-( … )`. [vec: expression.grammar.004, expression.grammar.005]
- **BE-EX-3** Literals: decimals need a digit before the optional point (`.5` does not parse) and have no exponent (`1e3` does not parse); strings are single-quoted with no escape mechanism (a quote cannot appear inside, `'it''s'` does not parse); double quotes are not strings. Parentheses group. [vec: expression.grammar.002, expression.grammar.007, expression.grammar.008]
- **BE-EX-4** Variables are exactly `event.code`, `event.timestamp` and `event.properties.<name>` with `<name>` an ASCII letter followed by letters, digits or underscores (`event.properties.1a`, `event.properties.a.b`, `event.foo` and spaces inside a variable do not parse). Property names are case-sensitive. [vec: expression.grammar.011]
- **BE-EX-5** Functions: `round`, `ceil`, `floor` take one or two arguments; `concat`, `least`, `greatest` take one or more. A name is recognised only all-lower-case, ALL-UPPER-CASE or Capitalised (`rOund` does not parse). [vec: expression.grammar.010, expression.grammar.015]
- **BE-EX-6** Only the space character separates tokens (a tab does not parse); any number of spaces is allowed between tokens, including before `(` of a call. [vec: expression.grammar.012, expression.grammar.013]
- **BE-EX-7** Parse failures: a metric whose expression does not parse cannot be saved (`expression: invalid_expression`), so the ingestion and processor surfaces never meet one; the preview endpoint answers 422 `{"expression": ["invalid_expression"]}`, and `{"expression": ["value_is_mandatory"]}` for an absent, null or blank expression. A blank (empty or whitespace-only) metric expression means "no expression" at ingestion. [vec: expression.grammar.005, expression.grammar.006, expression.grammar.007, expression.grammar.008, expression.grammar.011, expression.grammar.012, expression.grammar.015, expression.preview.003, expression.preview.004]

## 2. Values

- **BE-EX-10** A value is either a **number** — an exact decimal with a significand and a scale (number of fractional digits, possibly negative), arbitrary precision — or a **string**. A decimal literal is a number with the scale as written (`2.50` has scale 2). A string literal is always a string, even `'9'`: it is never converted to a number. [vec: expression.values.010, expression.text.001]
- **BE-EX-11** A property value that the surface delivers as a string (§5) is converted to a number when its whole text is a numeric string: an optional sign, digits and/or a fraction with at least one digit overall (`5.`, `.5`, `-.5`), underscores after the first digit ignored, even doubled or trailing (`1_000`, `1__0` = 10, `1_` = 1; a leading `_1` stays a string), an optional exponent `e`/`E` with optional sign (`1e3`, `+.5e2`); no surrounding whitespace (`" 5"` stays a string), no hexadecimal, no `inf`/`NaN`, no thousands separators. Any other text stays a string. [vec: expression.values.001, expression.values.002, expression.values.006, expression.values.007, expression.values.008, expression.values.009, expression.values.014, expression.functions.010]
- **BE-EX-12** `event.code` is always a string (a numeric code such as `"7"` is not converted: `event.code + 1` fails); `event.timestamp` is a number whose value depends on the surface (§5). [vec: expression.values.011, expression.rails.001, expression.rails.001x, expression.ep.001, expression.preview.006]
- **BE-EX-13** Reading a property the event does not have fails the evaluation with the message `Variable: <name> not found`. [vec: expression.values.004]
- **BE-EX-14** Arithmetic operands, `least`/`greatest` arguments and the digits argument of `round`/`ceil`/`floor` must be numbers; a string there fails the evaluation with the message `Expected a decimal`. [vec: expression.values.003, expression.values.008, expression.values.009, expression.values.010, expression.functions.008]

## 3. Operations

- **BE-EX-15** `+`, `-` and `*` are exact. The scale of a sum or difference is the larger operand scale; the scale of a product is the sum of the operand scales (`1.5 * 1.50` = 2.250). Integers of any size are exact. [vec: expression.values.001, expression.values.012, expression.text.006, expression.arith.006, expression.rails.009]
- **BE-EX-16** `/`: when the divisor's significand divides the dividend's significand exactly, the quotient keeps scale (dividend scale − divisor scale) (`6.00 / 3` = 2.00, `10.0 / 4` = 2.5); otherwise the quotient is produced digit by digit until it is exact (`10 / 4` = 2.5, `1 / 8` = 0.125) or has 100 significant digits, the last one rounded half away from zero (`1 / 3` = 0.333…3 with 100 threes, `2 / 3` ends in …67; an exact tie at the 101st digit rounds away from zero for both signs). Later operations use the rounded quotient (`1 / 7 * 7` = 1.000…0003). Two corners: a zero dividend is returned unchanged, with its own scale (`0.00 / 3` = 0.00); and when the integer part of the quotient alone has 100 digits or more it is kept whole and rounded half away from zero at its first fractional digit (`(10^120 + 1) / 3` = 333…334, 120 digits). [vec: expression.arith.001, expression.arith.002, expression.arith.003, expression.arith.005, expression.arith.006, expression.arith.008, expression.text.007]
- **BE-EX-17** Division by zero does not produce an evaluation error in the reference. Ingestion and preview: the request fails with an internal error (HTTP 500; nothing stored or published; the server keeps serving). Processor: the engine aborts the whole processor process before the record is committed, so the record is read again after a restart — a poison record; the restart loop is inferred from the processor's commit rule, `events-processor-spec` delivery chapter, not run end to end. Corrected profile (RBD-37, proposed): an evaluation failure like any other (422 at ingestion, dead letter `evaluate_expression` in the processor). [vec: expression.div_zero.001x, expression.div_zero.002x]
- **BE-EX-18** `round(x[, d])`, `ceil(x[, d])`, `floor(x[, d])`: `d` defaults to 0, must be a number and is truncated toward zero to an integer (`round(2.345, 1.9)` uses 1); the result has scale exactly `d` (`round(2, 3)` = 2.000, visible through `concat`); `round` is half away from zero (2.5 → 3, −2.5 → −3), `ceil` rounds toward +∞ (−2.5 → −2), `floor` toward −∞ (−2.341 at 1 → −2.4); a negative `d` rounds to tens, hundreds… (`round(1234.5, -2)` = 1200). [vec: expression.functions.001, expression.functions.002, expression.functions.003, expression.functions.004, expression.functions.005, expression.functions.006, expression.functions.008, expression.rails.008, expression.preview.002, expression.text.004]
- **BE-EX-19** `least(…)` / `greatest(…)` return the smallest / largest numeric argument, unchanged (its own scale); on equal values `least` keeps the first and `greatest` the last (`least(1.0, 1)` is `1.0`, `greatest(1.0, 1)` is `1`). [vec: expression.functions.010, expression.functions.011, expression.functions.012]
- **BE-EX-20** `concat(…)` returns a string: the text of every argument (strings as they are, numbers in the number text form of BE-EX-21) joined without separator. An expression's result is a number or a string; nothing else exists. [vec: expression.values.002, expression.values.011, expression.text.001]

## 4. Number text form

Numbers become text in `concat`, in the processor's result (BE-EX-41) and nowhere else (the ingestion and preview
surfaces re-format numbers, BE-EX-31/50). Write a number as significand `c` (an integer, trailing zeros kept) and
scale `s`, value = c × 10^−s, and let `n` be the number of digits of |c|.

- **BE-EX-21** The engine's text of a number: (a) when s − n > 5 (more than five zeros between the decimal point and the first significant digit): scientific form — first digit, then `.` and the remaining digits if there are any, then `E`, the exponent's sign and value (`0.0000001` → `1E-7`, `0.00000015` → `1.5E-7`, while `0.0000012` stays plain); (b) else when s < −15 (more than fifteen implied integer zeros): the digits of c, `e+` and −s (`1e+21`, `1235e+16`, and `10e+19` for a value that arrived as `1.0e+20`); (c) else plain notation: c followed by −s zeros when s ≤ 0 (`1200`), otherwise c with a point before its last s digits, zero-padded (`2.50`, `2.250`, `0.0000012`); a minus sign prefixes negative values. (d) Zero: the engine build embedded by the billing API prints `0` whatever the scale, the build embedded by the events-processor keeps the scale (`0.00`). [vec: expression.text.001, expression.text.002, expression.text.003, expression.text.004, expression.text.005, expression.text.006, expression.text.007, expression.text.008, expression.ep.009, expression.ep.011, expression.ep.012, expression.rails.006]

## 5. Surfaces

### 5.1 Ingestion (billing API)

- **BE-EX-30** The engine sees: `event.code` = the event's code; `event.timestamp` = the event time in whole seconds, rounded down (the fraction is dropped: `1741007009.123` → 1741007009); each property converted from its JSON value: integers → numbers (exact); non-integer numbers → numbers built from the binary64 value's shortest round-trip text in exponent-aware form (`0.1` → 0.1; 1e20 arrives as `1.0e+20`, i.e. significand 10, scale −19); strings → strings (BE-EX-11 applies on use); `true`/`false` → the strings `true`/`false`; null → the empty string; objects and arrays → the reference's own text rendering (`{"x" => 1}`, `[1, 2]`). Corrected (RBD-38, proposed): `event.timestamp` keeps the millisecond fraction as on the processor surface. [vec: expression.rails.001, expression.rails.001x, expression.rails.002, expression.rails.003, expression.rails.005, expression.rails.006, expression.values.012]
- **BE-EX-31** The result is written into `properties[field_name]` as a JSON string: a number in plain notation with trailing fractional zeros removed and at least one fractional digit (`3` → `"3.0"`, 2.250 → `"2.25"`, `1E-7` → `"0.0000001"`, 1200 → `"1200.0"`, 1/3 → `"0.333…3"`); a string as is. A failure rejects the event (BE-EV-52). [vec: expression.rails.007, expression.rails.008, expression.rails.009, expression.values.001, expression.functions.006, expression.arith.002]
- **BE-EX-32** An event time before 1970 makes the evaluation fail with an internal error (HTTP 500) instead of an evaluation error; a rebuild should evaluate it like any other event (proposed rebuild decision, owner). [vec: none (prose only: the reference answers an internal error, which the kit does not grade until ruled)]

### 5.2 Events-processor

- **BE-EX-40** The processor evaluates the expression only for records whose `source` is not `http_ruby` (`events-processor-spec` EP-G1). The engine sees the enriched record as JSON: `code`, `timestamp` = the processor's emitted seconds with their millisecond fraction (`1741007009.123`, RBD-38), and `properties` as the processor holds them (numbers re-encoded in their shortest binary64 form, `events-processor-spec` EP-C5; numeric strings stay strings and convert on use, BE-EX-11); other members are ignored. Every property value must be a number or a string: a boolean, null, object or array ANYWHERE in `properties` (even one the expression does not read), or `properties` null, fails the evaluation. [vec: expression.ep.001, expression.ep.002, expression.ep.004, expression.ep.006, expression.ep.008, expression.ep.013]
- **BE-EX-41** The result is stored as a JSON string holding the engine's text (BE-EX-21): numbers keep their scale and form (`"4"`, `"0.2"`, `"36"`, `"5.00"`, `"1E-7"`, `"1e+21"`, `"0.00"`), strings as is; this string becomes the record's value (`events-processor-spec` EP-F3, EP-G2). [vec: expression.ep.002, expression.ep.009, expression.ep.011, expression.ep.012]
- **BE-EX-42** A failed evaluation (parse, missing variable, type error, invalid property type) sends the record to the dead letter with code `evaluate_expression` (`events-processor-spec` EP-G3); a division by zero aborts the processor (BE-EX-17). [vec: expression.ep.006, expression.ep.008, expression.div_zero.002x]

### 5.3 Preview endpoint

- **BE-EX-50** `POST /api/v1/billable_metrics/evaluate_expression` with body `{"expression": …, "event": {"code", "timestamp", "properties"}}`: absent/null/blank expression → 422 `{"expression": ["value_is_mandatory"]}`; unparsable → 422 `{"expression": ["invalid_expression"]}`; any evaluation failure → 422 `{"event": ["invalid_event"]}` (an absent `event` evaluates with code `""`, the current time and no properties, so an expression that reads a property fails this way). The engine sees `code` as text (`""` when absent); `timestamp` reduced to whole seconds leniently — a JSON number truncated toward zero, a text read as its leading integer digits (`"1700000000.9"` → 1700000000, `"abc"` → 0), absent → the current time; every property converted to TEXT first (numbers by their binary64 text, `true` → `"true"`, null → `""`), so numbers behave as numeric strings. 200 answers `{"expression_result": {"value": …}}` with a number in plain notation with at least one fractional digit (`"21.0"`, `"2.0"`) or the string. [vec: expression.preview.001, expression.preview.002, expression.preview.003, expression.preview.004, expression.preview.005, expression.preview.006]
- **BE-EX-51** A negative timestamp on the preview surface fails with an internal error (HTTP 500). [vec: none (prose only: internal error, not graded)]

## 6. Surface differences (summary)

| Aspect | Ingestion | Processor | Preview |
|---|---|---|---|
| `event.timestamp` | whole seconds (floor) | seconds with ms fraction | whole seconds (lenient text) |
| boolean property | string `true` | evaluation fails | string `true` |
| null property | empty string | evaluation fails | empty string |
| object/array property | reference text rendering | evaluation fails | reference text rendering |
| non-integer number property | binary64 shortest text (`1.0e+20`) | as the processor re-encodes it (EP-C5) | its binary64 text |
| number result written as | plain, ≥ 1 fractional digit (`"5.0"`) | engine text (`"5.00"`, `"1E-7"`) | plain, ≥ 1 fractional digit |
| zero inside `concat` | `0` | keeps scale (`0.00`) | `0` |
| evaluation failure | 422, text detail | dead letter `evaluate_expression` | 422 `invalid_event` |
| division by zero | internal error (HTTP 500) | processor aborts (repeatedly) | internal error (HTTP 500) |

## 7. Algorithm sketch (fresh pseudocode)

```
parse(text) → AST or parse_error           # recursive descent: expression := term {op term}, precedence * / over + -
eval(node, ev):
  literal decimal → Number(text) ; literal string → Str(text)
  event.code → Str(ev.code) ; event.timestamp → to_value(ev.timestamp)
  event.properties.k → k in ev.props ? to_value(ev.props[k]) : fail("Variable: k not found")
  -x → Number(-num(eval(x)))
  a op b → num(eval(a)) op num(eval(b))        # num(): Str fails "Expected a decimal"; / per BE-EX-16
  round|ceil|floor(x, d=0) → rescale(num(eval(x)), trunc(num(eval(d))), mode)
  least|greatest(args) → min|max of num(eval(arg))
  concat(args) → Str(join(text(eval(arg))))    # text(): BE-EX-21
to_value(v): Str(s) → parses as numeric string (BE-EX-11) ? Number(s) : Str(s) ; Number → Number
```

## 8. Edge cases (people get these wrong)

1. `greatest('9', 7)` fails: string literals are never numbers; only property strings convert (BE-EX-10/11).
2. `event.timestamp` differs by surface: whole seconds at ingestion, milliseconds in the processor (BE-EX-30/40, RBD-38).
3. A boolean anywhere in the properties breaks every expression in the processor, but is the string `true` at ingestion (BE-EX-30/40).
4. Division keeps 100 significant digits, rounding half away from zero, and only when the quotient is not exact (BE-EX-16).
5. The stored ingestion result is `"3.0"`, not `3` or `"3"`; the processor stores `"3"` (BE-EX-31/41).
6. `concat(0.0000001)` is `1E-7`; `concat(round(1234.5, -2))` is `1200` (BE-EX-21).
7. Division by zero is an internal error (HTTP 500) in the billing API and aborts the events-processor; it is never an ordinary evaluation error in the reference (BE-EX-17).
8. Tabs are not whitespace; `ROUND` and `Round` parse, `rOund` does not (BE-EX-5/6).

## 9. Vectors

| Rules | Vectors |
|---|---|
| BE-EX-1..7 grammar | `expression.grammar.*`, `expression.preview.003/004` |
| BE-EX-10..14 values | `expression.values.*` |
| BE-EX-15..20 operations | `expression.arith.*`, `expression.functions.*`, `expression.div_zero.*` |
| BE-EX-21 number text | `expression.text.*`, `expression.ep.009..012` |
| BE-EX-30..32 ingestion | `expression.rails.*` |
| BE-EX-40..42 processor | `expression.ep.*` |
| BE-EX-50..51 preview | `expression.preview.*` |

## Provenance (maintainers)

| Rules | Reference behaviour at the pin |
|---|---|
| engine | gem `lago-expression` at revision `2abd2b3` (`$API/Gemfile:123`); its core sources (`expression-core/src/grammar.pest`, `parser.rs`, `evaluate.rs`, `event.rs`) are identical to the `v0.2.0` tag the events-processor Dockerfile builds; the two builds differ only in the decimal library patch release (0.4.10 in the billing API build, 0.4.6 in the processor build), which explains BE-EX-21 (d) |
| BE-EX-1..7 | engine grammar and parser; metric validation `$API/app/models/billable_metric.rb:53`, `:120-125`; preview `$API/app/services/billable_metrics/evaluate_expression_service.rb:13-21` |
| BE-EX-10..21 | engine evaluator (`evaluate.rs`) and the decimal library's division and display rules |
| BE-EX-30, 31 | `$API/app/services/events/calculate_expression_service.rb:13-31`; binding `expression-ruby/ext/lago_expression/src/lib.rs` (numeric → decimal from its text, other values → their text, timestamp as an unsigned integer) |
| BE-EX-40..42 | `events-processor/processors/events_processor/enrichment_service.go:100-140`; binding `expression-go/src/lib.rs` (NULL on any failure) |
| BE-EX-50, 51 | `$API/app/services/billable_metrics/evaluate_expression_service.rb:13-33`; `$API/app/controllers/api/v1/billable_metrics_controller.rb:105-121`, `:141-147` |

Executions (2026-10-02):

- `oracle.sh run spec/services/billable_metrics/evaluate_expression_service_spec.rb
  spec/services/events/calculate_expression_service_spec.rb spec/services/events/create_service_spec.rb
  spec/services/events/create_batch_service_spec.rb` → 51/51 green; with
  `spec/requests/api/v1/events_controller_spec.rb spec/requests/api/v1/billable_metrics_controller_spec.rb
  spec/models/billable_metric_spec.rb` → 128/128 green (database `lago_api_test_a3`, ruby-4.0.6).
- Oracle module `scripts/maintainer/oracle-adapter/ops/expression.rb`: ingestion vectors go through a real metric
  and `POST /api/v1/events`; preview vectors through the real endpoint; processor vectors call the engine library
  built from the `v0.2.0` tag (the processor's build) in a subprocess. kitrun against the oracle: all
  `both`/`compat` vectors PASS (hand-off report).
- Cross-check: every ingestion and preview vector re-evaluated directly on the processor build of the engine with the
  ingestion/preview input conversions applied: 70 agree, 1 differs exactly as BE-EX-21 (d) predicts
  (`expression.text.008`), 2 skipped (blank expression, object rendering).
- Processor values agree with the events-processor black-box goldens (`events-processor-spec` EP-G2: `"4"`,
  `"0.2"`, `"6"`, `"36"`, `"1741007009.123"`).
- Division by zero (BE-EX-17): the ingestion binding raises a Ruby `fatal`; a process evaluating it directly on its main
  thread exits with status 1, but inside the request stack it surfaces as an error: the pinned app under its own web
  server (Puma 7.2.1) answered HTTP 500 on ingestion, batch and preview and kept serving (verification probe,
  2026-10-02). A Go program calling the processor's binding receives SIGABRT.
- Update triggers: a pin bump that moves the engine revision; a change of the decimal library; any change to the
  ingestion, processor or preview call sites.
