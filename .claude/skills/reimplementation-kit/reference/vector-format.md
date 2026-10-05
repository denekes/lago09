# Vector format (kit_schema 1)

> Licence note: the vectors record observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` and of the Lago
> events-processor at tree `83e012866f29`. They are behavioural data, not source code. Read
> `legal-and-provenance.md` before using the kit for a proprietary rebuild.

Normative definition of a kit **unit vector**: file layout, envelope, value encodings, comparison rules, evidence,
profiles, the op catalogue and the validator rules. The machine-readable forms are `schemas/vector.schema.json`,
`schemas/common.schema.json` and `schemas/ops/<area>.<op>.schema.json`. Scenario files (end-to-end, `scn.*`) are
specified in `scenario-tier.md`; the events-processor black-box goldens in `events-processor-spec`.

<!-- evidence-check: off normative spec; evidence = scripts/selftest/test_runner.py (runner behaviour) and validate-vectors.py (format rules) -->

## 1. Files and ids

| Rule | Statement |
|---|---|
| VF-1 | A vector file is UTF-8 JSON Lines: one compact JSON object per line, LF endings, a final newline, no blank lines in shipped files. |
| VF-2 | File name `<area>[.<topic>].jsonl`; every vector in it has `area` = the first file-name segment. Example: `pricing.models.jsonl` holds only `pricing.*` vectors. |
| VF-3 | Shipped unit vectors live in `<skill>/vectors/` (`billing-engine-spec/vectors/`, `events-processor-spec/vectors/`). Runner fixtures live in `reimplementation-kit/selftest/`. The maintainer holdout lives in `reimplementation-kit/maintainer-data/holdout/`, one file per shipped file with the same name, and is never in a clean-room pack (section 10). |
| VF-4 | Lines are sorted by `id` (plain code-point order). |
| VF-5 | `id` matches `^(domain\|events\|expression\|aggregation\|pricing\|periods\|invoice\|credit_notes\|wallets\|progressive\|alerts\|api\|webhooks\|clock\|ep)(\.[a-z0-9_]+)+\.[0-9]{3}x?$`. The first segment is the area; the last is a three-digit serial; a trailing `x` marks a corrected twin. |
| VF-6 | Ids are unique across the whole kit, holdout included. A retired id is never reused for a different behaviour. |
| VF-7 | Scenario ids match `^scn(\.[a-z0-9_]+)+\.[0-9]{3}x?$`; one pretty-printed file per scenario named `<id>.json`. |

Areas and their spec homes:

| Area | Spec home | Area | Spec home |
|---|---|---|---|
| `domain` | billing-engine-spec 01 (BE-DM) | `credit_notes` | billing-engine-spec 08 (BE-CN) |
| `events` | billing-engine-spec 02 (BE-EV) | `wallets` | billing-engine-spec 09 (BE-WL) |
| `expression` | billing-engine-spec 03 (BE-EX) | `progressive`, `alerts` | billing-engine-spec 10 (BE-PB, BE-AL) |
| `aggregation` | billing-engine-spec 04 (BE-AG) | `api` | billing-engine-spec 11 (BE-API) |
| `pricing` | billing-engine-spec 05 (BE-PR) | `webhooks` | billing-engine-spec 12 (BE-WH) |
| `periods` | billing-engine-spec 06 (BE-SP) | `clock` | billing-engine-spec 13 (BE-CK) |
| `invoice` | billing-engine-spec 07 (BE-IV) | `ep` | events-processor-spec (EP-*) |

### 1.1 Rule ids and the `[vec: …]` convention

Spec chapters name every normative rule with an id (`BE-PR-14`, `EP-H1`, `RBD-43`, `KQ-7`). A rule is **defined**
where its id opens a list item, the first cell of a table row, a heading, or a bold anchor at the start of a line
(`- **BE-PR-14** …`, `| BE-PR-14 | … |`), **in its home chapter**: `BE-<XX>-n` in the billing-engine-spec chapter of
its prefix (section 1 table), `EP-*` in `events-processor-spec/reference/`, `RBD-n` in
`reimplementation-kit/reference/rebuild-decisions.md`; `KQ-n` wherever the register lives. The same anchor anywhere
else (a SKILL.md summary list, a chapter's table of the rebuild decisions it touches) is only a mention.

Every normative rule line ends with `[vec: <ids>]` listing vectors or scenarios that exercise it (`*` wildcards
allowed: `[vec: pricing.graduated.*]`). The tag must stand on the **same physical line** as the rule id: write each rule
on one line (a tag on a continuation line is not seen, and the rule counts as uncovered). A rule that cannot
be vectorised ends with `[vec: none (prose only: <reason>)]`. Vectors point back through their `rules` and `rbd`
arrays. `validate-vectors.py --rule-coverage` reports, per chapter, rules with vectors, prose-only rules, uncovered
rules and rules exercised only by holdout vectors (which a clean-room reader cannot see).

## 2. Envelope

| Field | Type | Req. | Meaning |
|---|---|---|---|
| `kit_schema` | `1` | yes | Envelope version; changes only on breaking envelope changes. |
| `id` | string | yes | See VF-5. |
| `area` | string | yes | First id segment; also the report bucket and the threshold key. |
| `op` | string | yes | Operation within the area; `<area>.<op>` must exist in `schemas/ops/`. |
| `title` | string ≤ 120 | yes | Neutral one-line description of the case. |
| `profile` | `both`/`compat`/`corrected` | yes | Section 6. |
| `ruling` | `decided`/`proposed` | yes | `proposed` only on corrected vectors whose rebuild decision awaits the owner. |
| `pair` | id or `null` | yes | The twin's id for a compat/corrected pair; `null` otherwise. |
| `rules` | [rule id] | yes | Spec rules exercised (may be empty only when `rbd` is not). |
| `rbd` | [RBD id] | yes | Rebuild decisions exercised (`rebuild-decisions.md`). |
| `tags` | [string] | yes | Section 7. |
| `input` | object | yes | Op input (schema `$defs.input`). Forwarded to the adapter **byte-for-byte**. |
| `expected` | object | yes | Op output subset (schema `$defs.output`), or `{"error": {...}}` (4.4). |
| `compare` | object | no | Per-path comparison overrides (4.2). |
| `strict` | boolean | no | `true`: objects in the output may not carry keys absent from `expected`. Default `false`. |
| `timeout_s` | integer | no | Per-vector call timeout override (default 5 s; 30 s with tag `slow`). |
| `evidence` | object | yes | Section 5. |
| `notes` | string | no | Neutral prose; never needed to understand the rule. Required for EXTRACTED vectors and for unpaired compat/corrected vectors. |

No other envelope keys are allowed. Example (a real kit line, wrapped for reading):

```json
{"kit_schema":1,"id":"domain.selftest.days_between.002","area":"domain","op":"days_between",
 "title":"Paris month containing the autumn DST change counts 31 days","profile":"both","ruling":"decided",
 "pair":null,"rules":[],"rbd":[],"tags":["core","dst"],
 "input":{"from":"2023-09-30T23:10:00Z","to":"2023-10-31T22:59:59Z","timezone":"Europe/Paris"},
 "expected":{"days":31},
 "evidence":{"kind":"EXECUTED","by":"oracle-adapter","ref":"$API/spec/services/utils/datetime_spec.rb:223",
             "pin":"591ae9005110","runtime":"ruby-4.0.6 (pinned)","executed_at":"2026-10-02"}}
```

## 3. Value encodings

| Kind | Encoding | Rule |
|---|---|---|
| Minor-unit money (`*_cents`) | JSON integer | \|x\| < 2^53; the currency is given alongside (`currency`, ISO 4217). |
| Precise money (`precise_*_cents`) | canonical decimal string | Value in minor units as the reference computes it; fee outputs carry the stored value, rounded half away from zero to 15 decimal places (billing-engine-spec BE-PR-87). |
| Major-unit amounts, unit amounts, rates, units, credits | canonical decimal string | |
| Counts, days, offsets, sequence numbers, exponents | JSON integer | |
| Canonical decimal | string `^-?(0\|[1-9][0-9]*)(\.[0-9]+)?$` | No exponent, no `+`, no leading zeros. Trailing zeros are allowed and are NOT significant unless the compare mode is `text`. |
| Payload literals | raw JSON | Charge `properties`, event `properties`, raw records, webhook objects are passed as-is (JSON floats allowed). When the literal spelling matters (`2.0` vs `2`, `1e21`, integers beyond 2^53), the vector uses a sibling `*_json` string holding the exact JSON text and the tag `literal`. |
| Instant | string | ISO-8601 with a zone: `YYYY-MM-DDTHH:MM:SS(.f{1,9})?(Z\|±HH:MM)`. Expected instants are written in UTC with `Z`. Precision up to nanoseconds is compared exactly. |
| Local date | string `YYYY-MM-DD` | Always interpreted with an IANA `timezone` given in the same object, an ancestor, or the op input. |
| Durations | integer | The field name says the unit (`_days`, `_seconds`). |
| Percent rates | canonical decimal string | In percent: `"20.0"` = 20 %. |
| Booleans, null | JSON | `null` in `expected` means "absent or null" unless the op schema says otherwise. |

- **NUM-1** No JSON float may appear in `input` or `expected` outside payload subtrees. Payload subtrees are the
  properties an op schema types as `payload` (`common.schema.json#/$defs/payload`, marker `x-kit-payload`) and, while
  an op schema is a skeleton, keys named `properties`, `payload`, `amount_details`, `object`, `metadata`, `raw`,
  `body`, `event`, `events`, `stored_event`, `message`, `params`, `failure` and every `*_json` key.
- **NUM-2** Integers with \|x\| ≥ 2^53 are written as decimal strings outside payloads.
- **NUM-3** Division results carry the reference's precision (for example 32 significant digits for a decimal
  division, 15 decimal places for stored precise amounts) and a `compare` scale stating how many places are
  normative.
- **TIME-1** A string that looks like a date-time must be a full instant with a zone (no zone-less local times).
- **TIME-2** Any behaviour that depends on "now" takes an explicit instant input (`now`, `at`, `billing_at`); a
  vector never depends on the wall clock of the machine that runs it.

## 4. Comparison rules

The runner compares the adapter's `output` with `expected` recursively. `expected` is a **subset**: keys absent from
`expected` are not graded (unless `strict`).

### 4.1 Default by the type of the expected value

| Expected value | Default mode | PASS when |
|---|---|---|
| JSON integer | integer-exact | actual is a JSON number with the same integral value (a non-integer spelling such as `103.0` passes with warning NUM-OUT) |
| canonical decimal string | `numeric` | actual is a decimal string or JSON number with the same value (`"1.50"` = `"1.5"`); a non-integer JSON number raises warning NUM-OUT (an integer JSON number does not); the warning is expected where a rule makes the reference itself answer a JSON number at that path, as for the range bounds echoed in `amount_details` (billing-engine-spec BE-PR-58, `pricing.gp.006`) |
| JSON float (payload subtrees only) | `numeric` | same value |
| instant string | `instant` | actual is an instant (any zone) denoting the same point in time, to the nanosecond |
| any other string | `text` | byte-equal |
| `true` / `false` | exact | actual is the same boolean (never `1`/`0`) |
| `null` | exact | actual is `null` or the key is absent |
| object | subset | every expected key matches; extra actual keys allowed unless `strict` |
| array | ordered | same length, element-wise match |

A string that is both a canonical decimal and meant as text (a counter rendered `"001"` is not canonical and is
compared as text; `"1234"` is canonical) needs an explicit `text` override when the spelling matters.

### 4.2 Explicit modes (`compare`)

`compare` maps a **path** to `{"mode": …}` plus mode parameters:

| Mode | Parameters | Meaning | Typical use |
|---|---|---|---|
| `exact` | | JSON equality: same type (integer literal vs non-integer literal), same value, objects with the same keys, arrays in order | enum values, ids |
| `text` | | byte-equal strings; a JSON number is compared by its literal spelling | API serialisation (`"1.0"` vs `"1"`), event-processor value strings, signatures, encoded bodies |
| `numeric` | `scale`: n (optional) | decimal equality; with `scale`, both sides rounded half away from zero to n places first | divisions (scale 15 for precise amounts, 5 for allocation shares, 2 for display checks) |
| `float64` | | both sides parsed as IEEE-754 binary64, then equal | compat vectors of "float island" behaviour |
| `abs_tol` | `tol`: decimal | \|expected − actual\| ≤ tol | timing windows |
| `range` | | expected is `{"min": d, "max": d}` (either may be absent/null); min ≤ actual ≤ max | randomised back-off |
| `instant` | | same instant | explicit form of the default |
| `set` | | arrays compared as multisets (each expected element must match a distinct actual element using the rules for `path[*]`) | groups, crossed thresholds, unordered lists |
| `ignore` | | the path is not graded | values the reference leaves undefined (for example the order of equal-timestamp running totals) |
| `subset` / `strict` | | objects: extra keys allowed / forbidden at this path, overriding the envelope `strict` | |

### 4.3 Paths

Path syntax: dotted keys and `[n]` indices relative to the output root (`amount_details.graduated_ranges[2].units`);
`[*]` matches any index and `*` any single key; `$` (or the empty path) is the whole output. When several patterns
match a node, the one with the fewest wildcards wins (on a tie, the one listed first in `compare`). `set` pairs
expected and actual elements by a maximum matching, so the outcome does not depend on element order. A pattern that matches nothing in `expected` is a validator
warning (CMP). `ignore` on `$` is forbidden.

### 4.4 Expected errors

`expected` = `{"error": {"code": C, "field": F}}` (exactly one top-level key `error`) means the reference reports a
**domain error**: the adapter must return an error result with code `C` (and `field` `F` when given). Codes are the
reference's error codes (`invalid_format`, `value_already_exist`, `invalid_graduated_ranges`, …) plus these kit codes,
used where the reference has no code of its own:

| Kit code | Meaning |
|---|---|
| `charge_model_error` | the reference raises instead of returning a value for this input (pricing) |
| `parse_error`, `evaluation_error` | expression language failures |
| `server_error` | the reference fails with an unhandled internal error (HTTP 500 at the API); the body of a 500 is not graded |
| `unknown_event_type` | a webhook event name that is not in the catalogue (`webhooks.type_info`) |
| `undecodable`, `invalid_timestamp` | `ep` area: a raw record the events-processor cannot decode, a timestamp it rejects (events-processor-spec processing-rules section 11) |

Protocol codes (`unsupported_op`, `bad_input`, `internal`) never appear in `expected`. Consequently no op output may
have a top-level key named `error`.

An `expected` of `{}` asserts only that the op succeeds (any output, no domain error).

### 4.5 Vector statuses

| Status | When |
|---|---|
| PASS | the comparison found no difference |
| FAIL | a difference (diff lines `path: expected X (mode) got Y`), an error where an output was expected, or the reverse |
| ERROR | the adapter answered `bad_input`/`internal`, crashed, wrote a non-JSON line or answered another call id |
| TIMEOUT | no answer within the call timeout |
| SKIP | the op is not in the adapter's `hello.ops`, or the adapter answered `unsupported_op` (counts as not passed) |
| UNRULED | the vector is `profile: corrected` with `ruling: proposed`; its outcome is shown in brackets and never graded |

## 5. Evidence

```json
"evidence": {"kind": "EXECUTED", "by": "oracle-adapter", "ref": "$API/spec/services/utils/datetime_spec.rb:214",
             "pin": "591ae9005110", "runtime": "ruby-4.0.6 (pinned)", "executed_at": "2026-10-02"}
```

| Kind | `by` values | Meaning |
|---|---|---|
| EXECUTED | `oracle-adapter`, `spec-green`, `harness`, `replay-on-lago` (billing); `go-binary`, `go-unit`, `ep-oracle` (events-processor) | the expected output was produced by running the reference at the pin: the oracle adapter, a reference spec example asserting exactly these values that ran green on the pinned toolchain, a harness loading the real source (record a substitute runtime in `runtime`; the validator warns until it is re-run on the pinned toolchain), a scenario replay, the Go binary or Go unit tests |
| RECOMPUTED | `recompute`, `sql-recompute`, `stdlib` | produced by an independent re-implementation and checked against a reference assertion or a derived expectation; every corrected vector is RECOMPUTED with `ref` = its RBD id(s) |
| EXTRACTED | `spec-read`, `code-read` | read from code or specs only; allowed only with tag `unexecuted` and a note; target 0 |

- `ref`: `$API/<path>:<line>[-<line>]` (lago-api at the pin), `events-processor/<path>:<line>` (events-processor
  tree), `RBD-n` (corrected vectors), `derived` (inputs constructed for the case; the evidence is the run itself),
  `EPC-nn`, `golden:<name>`, `corpus:<name>`, `fixture:<name>`. Several references are separated by `; ` (for example
  two spec citations, a citation plus `derived`, or the RBD ids of a corrected twin: `RBD-15; RBD-18`; the older
  comma form `RBD-15,RBD-18` is still accepted). `$API` refs are maintainer provenance: implementers never need them.
- `pin`: follows the vector's **area**, not the surface under test: `591ae9005110` for every billing area,
  `ep:83e012866f29` for `ep`.
- **Mixed-surface convention.** `expression` vectors with `mode: ep` describe the events-processor surface of the
  expression language but belong to the billing area, so they carry the billing pin `591ae9005110`. Their value is
  produced by the expression engine build the events-processor tree uses (lago-expression `v0.2.0`, through the
  oracle adapter at the billing pin), and `runtime` must name that engine build (for example `libexpression_go
  (lago-expression v0.2.0, events-processor engine build) via oracle adapter`); the validator warns when it does not.
  A pin bump of either side re-mints these vectors (`maintainer-oracle.md` section 6).
- `runtime`: what produced the value (`ruby-4.0.6 (pinned)`, `go1.25.0, events-processor tree 83e0128`,
  `python3 recompute`). `executed_at`: ISO date of the run.
- Kit gates (`validate-vectors.py --gate`, thresholds in `acceptance/thresholds.json` `kit_gates`): among
  `both`/`compat` billing unit vectors ≥ 95 % EXECUTED, ≤ 5 % RECOMPUTED (each with a note saying why the oracle cannot
  run it), 0 EXTRACTED; scenarios 100 % EXECUTED; `ep` both/compat vectors ≥ 95 % EXECUTED, the rest RECOMPUTED with
  a note, 0 EXTRACTED. Corrected twins are RECOMPUTED by definition and never count toward a gate. Holdout vectors
  count like shipped ones.

## 6. Profiles, pairs and rulings

| Profile | Meaning | Pairing |
|---|---|---|
| `both` | the reference behaviour is also the corrected behaviour | `pair: null`, `ruling: decided`, id without `x` |
| `compat` | the reference behaviour (quirks included) that the corrected profile changes | `pair` = `<id>x` |
| `corrected` | the behaviour a rebuild decision (RBD) asks for | id = `<compat id>x`, `pair` = the compat id; RECOMPUTED; `ruling` decided or proposed |

- Twins share `op`, `rules` and `rbd`; each lists at least one RBD.
- An unpaired `compat` vector (`pair: null`) is allowed when no corrected contract exists for that input; its
  `notes` say so. An unpaired `corrected` vector (id ending in `x`, `pair: null`) is allowed when the compat side
  cannot be expressed as a vector; its `notes` say why.
- The runner sends the run profile in every call. A run with `--profile compat` grades `both` + `compat` vectors;
  `--profile corrected` grades `both` + `corrected`. `ruling: proposed` vectors are reported as UNRULED and never
  count toward a threshold; when the owner rules, flip them to `decided` (or delete the twin).

## 7. Tags

| Tag | Meaning |
|---|---|
| `core` | must pass 100 % (CORE column of the report); never moved to the holdout |
| `boundary` | an edge of a rule (zero, tie, month end, DST, empty list) |
| `float-island` | the reference computes in binary floating point here; compat compares with `float64` |
| `premium` | behaviour gated by the reference's premium licence flag (the input carries `premium: true`) |
| `literal` | the exact spelling of a number matters (`*_json` fields, `text` compare) |
| `optional` | behaviour a rebuild may omit (graded, but a component may declare it out of scope) |
| `store-ch` | the ClickHouse event-store variant |
| `slow` | call timeout 30 s instead of 5 s |
| `unexecuted` | EXTRACTED evidence (must disappear before release) |
| `test-key` | the vector carries the kit's test-only private key (the only private key allowed in kit content) |
| `order-dependent` | the reference result depends on an order it does not define; the vector pins one with `compare` |
| `dst`, `negative`, `regression` | informational |

Other lowercase tags are accepted with a validator warning (TAG).

## 8. The op catalogue

Each op has one schema file `schemas/ops/<area>.<op>.schema.json`:

```json
{"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": "ops/domain.days_between.schema.json",
 "title": "domain.days_between", "description": "…",
 "x-kit": {"area": "domain", "op": "days_between", "status": "final", "since": "1.0.0",
           "owner": "billing-engine-spec reference/01-domain-model.md (BE-DM)", "stateful": false},
 "$defs": {"input":  {"type": "object", "required": ["from", "to", "timezone"], "properties": {…}},
           "output": {"type": "object", "properties": {"days": {"type": "integer"}}}}}
```

- `$defs.input` validates `input` (with `required`); `$defs.output` validates `expected` with every property
  optional (expected is a subset).
- `x-kit.status`: `skeleton` (field list from the plan; schema mismatches are validator warnings) or `final`
  (mismatches are errors; every optional input property must declare `default` or `x-kit-absent` text).
- An adapter must accept unknown input fields only when the schema marks them optional with a default; absence of
  an optional field always means its default.
- Versioning: `kit_version` (semver) versions the catalogue. A minor version may add ops and optional input fields
  whose absence reproduces the previous behaviour; anything else is a major version.
- `system.*` ops are stateful and used only by the scenario tier (`scenario-tier.md`); unit vectors never use them.

The catalogue below lists every op of `schemas/ops/` (116 ops on 2026-10-02: 111 unit-vector ops and the five
stateful `system.*` ops). The schema files are normative and this table is a summary; `python3
scripts/adapter_ref.py --list-ops` prints the current list with each schema's status, and the validator warns (OP)
when an op schema has no row here or a row names an op without a schema.

| Op | What it answers | Spec home |
|---|---|---|
| `domain.effective_timezone` | Effective time zone of a customer: its own zone, else the billing entity's, else UTC. | billing-engine-spec 01 |
| `domain.applicable_settings` | Settings a customer uses (zone, grace period, net payment term, issuing-date options, locale) after inheritance. | billing-engine-spec 01 |
| `domain.to_local` | An instant expressed in an IANA zone with the offset in force at that instant. | billing-engine-spec 01 |
| `domain.days_between` | Whole local days between two instants in a zone (DST-aware); one fewer for a period ended by an upgrade. | billing-engine-spec 01 |
| `domain.terminated_at_reached` | Whether a termination instant is reached at an instant (whole-second rounding). | billing-engine-spec 01 |
| `domain.round` | Round a decimal at a precision: round (half away from zero), ceil, floor. | billing-engine-spec 01 |
| `domain.to_minor_units` | Major-unit amount to minor units (half away from zero) plus the unrounded value. | billing-engine-spec 01 |
| `domain.currency_exponent` | Minor-unit data of a currency: exponent, minor units per major unit, accepted or not. | billing-engine-spec 01 |
| `domain.fee_taxes` | Per-tax rows and fee tax total of one fee after its coupon share. | billing-engine-spec 01 |
| `domain.document_prefix` | Document-number prefix of an organization or billing entity. | billing-engine-spec 01 |
| `domain.customer_slug` | Customer slug: organization prefix plus the zero-padded customer sequence. | billing-engine-spec 01 |
| `domain.next_sequential_id` | Next sequence value in a numbering scope. | billing-engine-spec 01 |
| `domain.invoice_number` | Invoice number after a status change (draft placeholder, per-customer or per-billing-entity numbering). | billing-engine-spec 01 |
| `domain.credit_note_number` | Credit-note number after a save. | billing-engine-spec 01 |
| `domain.code_reusable` | Whether a new record may take a code (uniqueness scopes, soft-deleted records). | billing-engine-spec 01 |
| `domain.subscription_external_id_valid` | Subscription external-id rule when a subscription enters a status. | billing-engine-spec 01 |
| `domain.charge_filter_code` | Generated code of a charge filter. | billing-engine-spec 01 |
| `events.parse_timestamp` | Event time as persisted, from the exact JSON text of `timestamp`. | billing-engine-spec 02 |
| `events.validate` | Outcome of submitting one event: HTTP status, error details, the event as accepted. | billing-engine-spec 02 |
| `events.validate_batch` | Outcome of submitting a batch: all-or-nothing, per-index error details. | billing-engine-spec 02 |
| `events.raw_message` | Message published on the raw events topic for one accepted event. | billing-engine-spec 02 |
| `events.duplicate_key` | Ingestion idempotency key of a store: the event fields that identify a repeat. | billing-engine-spec 02 |
| `expression.evaluate` | Evaluate a metric expression against one event on a surface: `rails` (ingestion), `ep` (events-processor), `preview` (test endpoint). | billing-engine-spec 03 |
| `aggregation.aggregate` | Aggregate a metric over one bucket's events of a charges window, optionally per group (store pg or ch). | billing-engine-spec 04 |
| `aggregation.matching_and_ignored` | Matching values and ignored combinations of one bucket of a charge with filters. | billing-engine-spec 04 |
| `aggregation.select_events` | Events a bucket selects with its matching/ignored filters, per store. | billing-engine-spec 04 |
| `aggregation.event_filter` | The charge filter one event is billed under. | billing-engine-spec 04 |
| `aggregation.group_keys` | Group values an event falls into for grouping keys, as the store reads them. | billing-engine-spec 04 |
| `aggregation.in_advance_units` | Units one pay-in-advance event adds and the running state cached after it. | billing-engine-spec 04 |
| `aggregation.current_usage_in_advance` | Current-usage units of a pay-in-advance sum charge: period total versus cached running state. | billing-engine-spec 04 |
| `pricing.charge_model` | Price one bucket's aggregation with a charge model (unrounded amount, unit amount, details). | billing-engine-spec 05 |
| `pricing.pay_in_advance` | Fee of one pay-in-advance event (delta pricing). | billing-engine-spec 05 |
| `pricing.fee_money` | Fee money fields from a charge-model result (clamp, rounding, truncated unit amount, persistence). | billing-engine-spec 05 |
| `pricing.true_up` | Charge-minimum true-up fee. | billing-engine-spec 05 |
| `pricing.pricing_unit` | Pricing-unit conversion of a charge result. | billing-engine-spec 05 |
| `pricing.validate_properties` | Charge-model property validation errors. | billing-engine-spec 05 |
| `pricing.validate_charge` | Charge-level constraints (pay in advance, proration, invoiceable, minimum, premium gates). | billing-engine-spec 05 |
| `pricing.default_properties` | Properties given to a charge created without properties. | billing-engine-spec 05 |
| `pricing.filter_properties` | Property slicing and renaming applied before storage. | billing-engine-spec 05 |
| `pricing.fixed_charge_units` | Units of a fixed charge over a period from its unit events. | billing-engine-spec 05 |
| `pricing.fixed_charge_fee` | Arrears fee of a fixed charge for a period. | billing-engine-spec 05 |
| `pricing.fixed_charge_in_advance` | Pay-in-advance fee after a fixed-charge unit change. | billing-engine-spec 05 |
| `pricing.projection` | Projected usage of a charge for the rest of its period. | billing-engine-spec 05 |
| `pricing.estimate_instant` | Instant estimate of the fee of one pay-in-advance event. | billing-engine-spec 05 |
| `pricing.simulate` | The price simulator. | billing-engine-spec 05 |
| `periods.boundaries` | Billing-run boundaries: subscription-fee period, usage-charges and fixed-charges windows, durations. | billing-engine-spec 06 |
| `periods.invoice_boundaries` | Boundaries recorded on an invoice for a billing reason (current-usage mode, termination swap, duplicate guard). | billing-engine-spec 06 |
| `periods.billing_days` | Dates within a range on which a subscription's billing period rolls over. | billing-engine-spec 06 |
| `periods.periodic_billing` | Outcome of the periodic billing selection for one subscription at a run instant. | billing-engine-spec 06 |
| `periods.chain` | Consecutive periodic runs of a subscription and the boundaries each bills. | billing-engine-spec 06 |
| `periods.single_day_price` | Price of one day of a plan (binary floating point). | billing-engine-spec 06 |
| `periods.subscription_fee` | Subscription fee of an invoice period: gate, amount basis, amount. | billing-engine-spec 06 |
| `periods.classify_change` | Upgrade or downgrade classification of a plan change. | billing-engine-spec 06 |
| `periods.trial_end` | Trial end of a subscription and whether it is in trial at an instant. | billing-engine-spec 06 |
| `periods.termination_credit_days` | Unused days and unused amount of a pay-in-advance period at termination. | billing-engine-spec 06 |
| `periods.create_status` | Status, start and side effects of a newly created subscription. | billing-engine-spec 06 |
| `periods.terminate` | Outcome of a termination request per subscription status. | billing-engine-spec 06 |
| `invoice.totals` | Invoice totals pipeline: progressive credits, coupons, taxes, credit notes, prepaid credits, payment status. | billing-engine-spec 07 |
| `invoice.fee_tax_selection` | Taxes a fee gets (selection precedence). | billing-engine-spec 07 |
| `invoice.apply_taxes` | Fee taxes, invoice tax rows, tax total and tax rate. | billing-engine-spec 07 |
| `invoice.coupon_order` | Order in which active applied coupons are tried. | billing-engine-spec 07 |
| `invoice.coupon_amount` | Amount one applied coupon takes from a base. | billing-engine-spec 07 |
| `invoice.coupon_distribution` | One applied coupon applied to an invoice: skip rules, base, per-fee shares, consumption. | billing-engine-spec 07 |
| `invoice.final_status` | Status of a generated subscription invoice (grace period, payment gate, zero-amount rule). | billing-engine-spec 07 |
| `invoice.issuing_date` | Issuing, expected finalization and payment due dates at generation. | billing-engine-spec 07 |
| `invoice.payment_due_date` | Issuing and payment due dates at finalization of a draft. | billing-engine-spec 07 |
| `invoice.available_to_credit` | Creditable, refundable, offsettable and due amounts of an invoice; the voidable predicate. | billing-engine-spec 07 |
| `invoice.void` | Voiding a finalized invoice, optionally with credit notes. | billing-engine-spec 07 |
| `invoice.commitment_true_up` | Minimum-commitment true-up fee of each run (start, periodic, termination) of one subscription. | billing-engine-spec 07 |
| `invoice.coupon_create` | Creating a catalogue coupon: required values, limitations, expiration check. | billing-engine-spec 07 |
| `invoice.coupon_apply` | Applying a coupon to a customer: copied values, overrides, reusability and overlap checks. | billing-engine-spec 07 |
| `credit_notes.compute` | Credit note on an invoice (items, taxes, rounding correction). | billing-engine-spec 08 |
| `credit_notes.estimate` | Credit-note estimate for proposed items. | billing-engine-spec 08 |
| `credit_notes.termination` | Automatic credit note at termination of a pay-in-advance subscription. | billing-engine-spec 08 |
| `credit_notes.validate` | Validation of a credit-note request. | billing-engine-spec 08 |
| `wallets.credits` | Credits to money and back for one wallet. | billing-engine-spec 09 |
| `wallets.top_up` | One wallet-transaction request: paid, granted and voided credits. | billing-engine-spec 09 |
| `wallets.topup_amount` | Paid and granted credits a recurring top-up rule asks for. | billing-engine-spec 09 |
| `wallets.threshold_top_up` | Whether a threshold top-up is requested after a balance change, and with which credits. | billing-engine-spec 09 |
| `wallets.interval_due` | Whether the interval top-up sweep requests a top-up for one wallet's rule. | billing-engine-spec 09 |
| `wallets.consumption_order` | Which inbound transactions of a traceable wallet an outbound amount consumes. | billing-engine-spec 09 |
| `wallets.allocate` | Prepaid credits applied to one finalized invoice. | billing-engine-spec 09 |
| `wallets.ongoing_balance` | Ongoing usage allocated over a customer's wallets and the resulting balances. | billing-engine-spec 09 |
| `progressive.lifetime_usage` | Lifetime usage of a subscription (historical, invoiced, current). | billing-engine-spec 10 |
| `progressive.check_thresholds` | Usage thresholds passed for a subscription. | billing-engine-spec 10 |
| `progressive.passed_amount` | Amount recorded as passed for an applied threshold. | billing-engine-spec 10 |
| `progressive.to_credit` | Credit of earlier progressive-billing invoices on the period invoice. | billing-engine-spec 10 |
| `alerts.measure` | Value an alert measures. | billing-engine-spec 10 |
| `alerts.crossed` | Thresholds an alert crosses between two measured values. | billing-engine-spec 10 |
| `api.auth_token` | API key extracted from the Authorization header. | billing-engine-spec 11 |
| `api.authorize` | Permission check of an authenticated API request. | billing-engine-spec 11 |
| `api.error_body` | HTTP status and exact JSON body of an API error. | billing-engine-spec 11 |
| `api.pagination_meta` | Pagination `meta` block and page size of an index endpoint. | billing-engine-spec 11 |
| `api.count_cache_key` | Key under which index endpoints cache their total count. | billing-engine-spec 11 |
| `webhooks.normalize_event_types` | Stored form and validity of an endpoint's event-type filter. | billing-engine-spec 12 |
| `webhooks.endpoint_receives` | Whether an endpoint with a stored filter receives an emitted webhook. | billing-engine-spec 12 |
| `webhooks.type_info` | Emitted webhook type and object type of one of the 75 configured event names. | billing-engine-spec 12 |
| `webhooks.payload_envelope` | Body posted for an emitted webhook (outputs `body`, `webhook_type`). | billing-engine-spec 12 |
| `webhooks.encode` | Exact bytes of a webhook body for a payload. | billing-engine-spec 12 |
| `webhooks.sign` | Signature headers of a webhook delivery (HMAC, RS256 JWT). | billing-engine-spec 12 |
| `webhooks.public_key` | Bodies of the public-key endpoints for an installation key. | billing-engine-spec 12 |
| `webhooks.retry_step` | One delivery attempt: success codes, retry state and back-off. | billing-engine-spec 12 |
| `clock.jobs_due` | Clock jobs that enqueue work during a window, with their number of runs. | billing-engine-spec 13 |
| `clock.termination_alert_due` | Subscriptions the termination-alert job notifies at an instant. | billing-engine-spec 13 |
| `clock.idempotency_key` | Idempotency key of a guarded resource. | billing-engine-spec 13 |
| `ep.decode` | Decode one raw-topic record. | events-processor-spec processing-rules |
| `ep.parse_timestamp` | Emitted timestamp and matching instant of a raw `timestamp` value. | events-processor-spec processing-rules |
| `ep.value_string` | Enriched `value` string and aggregation label for a metric and event properties. | events-processor-spec processing-rules |
| `ep.match_subscription` | Subscription an event is attached to. | events-processor-spec processing-rules |
| `ep.commit_offset` | Offset committed after one batch of one partition. | events-processor-spec processing-rules |
| `ep.refresh_member` | Refresh-flag member and score written for an enriched event. | events-processor-spec processing-rules |
| `system.reset` | Erase the implementation's tenants and create one empty tenant with the given settings. | scenario-tier.md (scenario tier only) |
| `system.set_clock` | Set the frozen wall clock for every later call. | scenario-tier.md (scenario tier only) |
| `system.api` | One REST API v1 call, answered after all follow-up work. | scenario-tier.md (scenario tier only) |
| `system.tick` | Run named clock jobs at the current clock, then drain. | scenario-tier.md (scenario tier only) |
| `system.snapshot` | The tenant's state as API v1 representations. | scenario-tier.md (scenario tier only) |

## 9. Validator rules (`scripts/validate-vectors.py`)

| Family | Level | Check |
|---|---|---|
| SCHEMA | error | envelope against `vector.schema.json`; `input`/`expected` against the op schema (warning while the op schema is a skeleton); a `final` op schema whose optional input lacks `default`/`x-kit-absent`; JSON parses; LF endings; final newline; no blank lines |
| ID | error | grammar; uniqueness across shipped files, selftest fixtures and holdout; sorted within a file; file area = id area = `area` |
| OP | error / warning | `<area>.<op>` exists in `schemas/ops/`; no `system.*` in unit vectors (errors); the section 8 table lists exactly the ops of `schemas/ops/` (warning) |
| PAIR | error | twin exists and points back; one compat and one corrected; same `op`, `rules`, `rbd`; compat/corrected cite an RBD; unpaired compat/corrected vectors carry a note |
| REF | error / warning | rule and RBD ids are defined in their home chapter (section 1.1; warning while that chapter is not written, or when the id is only mentioned); `[vec: …]` ids resolve (error with `--gate`) |
| NUM | error | NUM-1, NUM-2 |
| TIME | error / warning | TIME-1 (error); a local date without a time zone in scope (warning) |
| EVID | error / warning | kind/by consistency; EXTRACTED needs tag `unexecuted` + note; corrected → RECOMPUTED with `ref` = its RBD ids; pin per area; substitute runtime, unrecognised `ref` forms and a `mode: ep` expression vector whose `runtime` does not name the engine build warn |
| CMP | error / warning | modes and parameters valid; `range` needs `{min,max}`; `ignore` on `$` forbidden; patterns that match nothing warn |
| EXPECT | error / warning | expected errors never use protocol codes; `{}` warns |
| TAG | warning | unknown tag |
| BUDGET | error | the size caps below (whole-kit runs only) |
| CONTENT | error | no scratch or home paths, no cache-directory contents, no planning-document or discovery-note ids, no secrets (a private key only in a vector tagged `test-key`), no internal table names in scenarios, no UUID outside `schemas/allowed-uuids.json` unless obviously synthetic (half of its hex digits identical); UUIDs in unit vectors warn |
| HOLDOUT | error / warning | no shipped id appears in the holdout; twins are both shipped or both held out; no holdout id is written in shipped text (kit Markdown outside maintainer documents, scenarios, schemas, shipped vectors) (errors); a `[vec: …]` wildcard that matches only holdout vectors (warning, error with `--gate`) |
| TEXT | error / warning | kit Markdown: `$API/` citations only in "Provenance (maintainers)" sections (and in example `"ref"` lines inside code blocks); every reference chapter carries an AGPL note (warning) |
| GATE | error | `--gate`: evidence mix of section 5 |
| COVER | warning (error with `--gate`) | `--rule-coverage`: every defined BE/EP rule has a vector or a prose-only marker; holdout vectors do not count as coverage (`holdout_only` column) |

### 9.1 Size budget

Caps are read from `acceptance/thresholds.json` `kit_budget` (the validator's built-in defaults are the same values)
and checked on whole-kit runs; every run prints a `SIZES` line with the measured buckets.

| Bucket | Counts | Cap (bytes) |
|---|---|---|
| `billing_unit` | `billing-engine-spec/vectors/*.jsonl` plus holdout files not named `ep.*` | 1,450,000 |
| `scenarios` | `billing-engine-spec/scenarios/*` (scenario files and `MANIFEST.md`) | 600,000 |
| `ep_conformance` | `events-processor-spec/conformance/**` | 650,000 |
| `ep_units` | `events-processor-spec/vectors/*.jsonl` plus holdout `ep.*.jsonl` | 130,000 |
| `schemas_meta` | `reimplementation-kit/schemas/**/*.json`, `acceptance/*`, `billing-engine-spec/scenarios/MANIFEST.md` | 420,000 |
| `total` | the five buckets plus `reimplementation-kit/kit.json` (the hash manifest counts only here) | 3,000,000 |

One scenario: at most 16 KB in compact JSON (target 12 KB, warning above it); at most five scenarios may reach 24 KB.
Keep new vectors compact (600-750 bytes is typical): short titles, defaults left out, one evidence citation.

Output: `ERROR|WARN <RULE> <file>:<line> [<id>] <message>` lines, a `SIZES …` line, then
`SUMMARY validate-vectors: files=N vectors=N scenarios=N errors=N warnings=N`; exit 0 (no errors), 1 (errors),
2 (usage). A file named twice (relative path and discovery) is checked once.

## 10. Maintainer data: holdout and the `kit.json` manifest

**Holdout.** `scripts/maintainer/holdout-split.py` moves a seeded, stratified sample into
`reimplementation-kit/maintainer-data/holdout/<same file name>` (lines byte-identical, sorted by id) and removes it
from the shipped file. It works per stratum (file, op) with a target of 20 % of the stratum (`--fraction`), in an
order fixed by the seed (`--seed`, rotated before an acceptance run), and computes the split over shipped plus
current holdout vectors, so a re-run with the same seed changes nothing and a new seed moves earlier holdout vectors
back. It never selects `core` vectors, vectors whose id is written out in shipped kit text (a wildcard does not
count), `ep.*` vectors (unless `--include-ep`) or the runner fixtures; twins move together; and it keeps at least one
shipped vector for every rule id, RBD id and `[vec: …]` wildcard. `--prune-vec-tags` also admits vectors named only
in `[vec: …]` tags and removes them from those tags on `--write` (every tag keeps a shipped id). `--check` prints the
per-file counts and the pending moves (exit 1 when the tree differs), `--write` applies them. Run
`validate-vectors.py` afterwards (HOLDOUT, REF and COVER clean) and grade with `kitrun.py --include-holdout
reimplementation-kit/maintainer-data/holdout`.

**Manifest.** `scripts/maintainer/make-kit-json.py --write` (run last, after the split) writes:

```json
{"kit_version":"1.6.0","kit_schema":1,"proto":1,"pins":{"lago_api":"591ae9005110","events_processor_tree":"83e012866f29"},
 "generated_by":"reimplementation-kit/scripts/maintainer/make-kit-json.py","files":{
"billing-engine-spec/reference/05-pricing-and-fees.md":"<sha256>",
"billing-engine-spec/vectors/pricing.models.jsonl":{"sha256":"<sha256>","vectors":106},
"reimplementation-kit/maintainer-data/holdout/pricing.models.jsonl":{"sha256":"<sha256>","vectors":21,"maintainer":true}}}
```

Every file of the three kit skills is listed (one per line, sorted, no timestamp), except `kit.json` itself and
`__pycache__`/`*.pyc`/`.DS_Store`/`*.tmp`. A plain file maps to its sha256; vector files add their vector count;
maintainer-only files (what `kit-pack.sh --cleanroom` strips: `scripts/maintainer/`, `maintainer-data/`,
`reference/maintainer-oracle.md`, any file with the MAINTAINER-ONLY header) add `"maintainer": true`. `--check`
reports ADDED/REMOVED/CHANGED entries and exits 1 when the file is absent or stale. `kitrun.py` reads `kit_version`
from it (default `1.6.0-dev`); `kit-pack.sh` verifies every listed hash (maintainer entries may be absent from a
clean-room pack).

## Provenance (maintainers)

- Format derived from the kit plan of record (2026-10-02) sections 2-3, revised in the fix round of 2026-10-02 (size
  caps, home-chapter definitions, holdout and manifest tools, the regenerated op catalogue); the runner semantics are
  pinned by `scripts/selftest/test_runner.py` (18 tests, `python3 scripts/selftest/test_runner.py` → `Ran 18 tests …
  OK`, 2026-10-02).
- Example vector `domain.selftest.days_between.002`: `$API/spec/services/utils/datetime_spec.rb:223` @591ae90,
  re-executed through the oracle adapter (`kitrun.py --impl-cmd "scripts/maintainer/oracle.sh adapter" --vectors
  selftest/domain.selftest.jsonl` → `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=23 passed=23 skipped_ops=0
  exit=0`, 2026-10-02).
- Holdout and manifest tools checked on a scratch copy of the kit (2026-10-02): `holdout-split.py --write` then
  `--check` → `moves=0`; `validate-vectors.py` 0 errors before and after with unchanged rule coverage; `make-kit-json.py
  --write` then `--check` → `changed=0`; `kit-pack.sh --cleanroom` → manifest 0 problems, forbidden-content 0,
  validator 0 errors inside the pack.
- Kit 1.1.0 (2026-10-05): the precise-money row of section 3 now says what fee outputs carry (the stored value at 15
  places, billing-engine-spec BE-PR-87; the 1.0.0 text "unrounded" contradicted the fee vectors); the section 8 rows of
  `webhooks.type_info` (the 75 configured names, billing-engine-spec 12 BE-WH-11) and `webhooks.payload_envelope`
  (outputs `body` and `webhook_type`) follow their op schemas; the catalogue still has one row per op schema (116).
- Kit 1.2.0 (2026-10-05): the canonical-decimal row of section 4.1 says where NUM-OUT is expected (the range bounds
  that billing-engine-spec BE-PR-58 echoes as JSON numbers); no op or envelope change.
- Kit 1.3.0 (2026-10-05): the `billing_unit` size cap of section 9.1 is 1,450,000 bytes (was 1,400,000); no op or
  envelope change.
- Update triggers: a new op or mode (minor `kit_version`; add its row to section 8), an envelope change
  (`kit_schema`), a pin bump (`maintainer-oracle.md` re-mint procedure), a budget decision (`thresholds.json`
  `kit_budget` and section 9.1 together).
