# Rebuild method: build order and phase exit criteria

> Licence note: the kit describes the behaviour of lago-api (AGPL-3.0) at pin `591ae90` and of the Lago
> events-processor at tree `83e012866f29` in neutral form. A rebuild uses the kit, never the reference source; see
> `legal-and-provenance.md`.

How to rebuild a system equivalent to the Lago billing engine and events-processor from the kit alone, in an order
where every phase ends with a measurable gate. The gates are kitrun runs (`adapter-protocol.md`) against the
thresholds in `acceptance/thresholds.json`; the events-processor gate is its black-box suite.

<!-- evidence-check: off normative method; evidence = the kitrun/run-suite commands named in each phase gate -->

## 1. Principles

1. **Vectors are the contract, chapters are the explanation.** Each chapter rule ends with the vector ids that pin
   it (`[vec: …]`). When prose and a vector disagree, the vector wins and the disagreement is a kit defect to report
   (`acceptance-and-grading.md` §5).
2. **Build bottom-up, grade continuously.** Each phase adds ops to one adapter process. Run kitrun after every
   change; never move on with a red `core` vector.
3. **Pick the profile first** (§2): it decides how quirks are implemented. Keep both possible behind one switch if
   the deployment will migrate from Lago.
4. **Exact decimals everywhere** except where a `compat` vector is tagged `float-island` (§4.3). Money is stored in
   minor units; division results keep the precision the vectors show.
5. **Time is an input.** Every op that depends on "now" receives an instant; local dates are computed in the
   effective time zone (customer → billing entity → UTC).
6. **Do not read `expected` to build tables.** Implement the rule; the holdout (20 % of vectors you never see)
   detects overfitting.

## 2. Choosing a profile

| Situation | Profile to implement | Why |
|---|---|---|
| Migration from a running Lago (same invoices before and after) | `compat` | reproduces the reference including its quirks (float islands, store differences, delivery loss modes) |
| Greenfield product "similar to Lago" | `corrected` | the rebuild decisions (RBDs) fix defects; `proposed` decisions are advisory until the owner rules |
| Migration first, then fixes | both, switched per tenant | the runner sends the profile in every call; grade both |

A `both` vector is binding in either profile. `compat`/`corrected` twins differ only where an RBD changes
behaviour (`rebuild-decisions.md`).

## 3. Architecture the kit assumes (and what it leaves free)

The kit fixes **observable behaviour**: computed amounts, dates, statuses, document numbers, API payloads, webhook
bytes and signatures, event-processor topic records. It does not fix storage layout, languages, frameworks,
process topology or queueing technology. Functional blocks a rebuild needs (each maps to chapters and ops):

```
 REST API v1 ──► catalogue (metrics, plans, charges, taxes, coupons, add-ons, customers)
     │                      │
     │ events               ▼
     ├────────► ingestion ─► event store ─► aggregation ─► pricing ─► fees ─┐
     │          (validate,    (pg or ch     (per metric    (charge     (money │
     │           idempotency)  variant)      type, filters) models)     rules) │
     │                                                                       ▼
     │   clock (hourly) ─► billing periods ─► invoice pipeline (coupons, taxes, credit notes,
     │                                         wallets/prepaid, progressive billing) ─► webhooks
     └─ events-processor (Kafka consumer: raw → enriched / in-advance / dead-letter, refresh flag)
```

## 4. Phases

Each phase lists what to read, what to build, which ops it answers and its gate. "Gate" commands assume
`A="python3 my_adapter.py"` and are run from the kit root.

### P0 — Read and wire the harness

- Read: this skill's SKILL.md, `vector-format.md`, `adapter-protocol.md`, `billing-engine-spec` SKILL.md and its
  conventions section, `appendix-enums.md`, `glossary.md`.
- Build: an adapter process skeleton (copy the loop of `scripts/adapter_ref.py` or port it), exact-decimal JSON
  parsing, canonical decimal and instant output helpers.
- Gate: `bash scripts/kit-selftest.sh` → `SUMMARY kit-selftest: … fail=0`; `kitrun.py --impl-cmd "$A" --vectors
  selftest/domain.selftest.jsonl --only round` → 14/14 PASS once `domain.round` is implemented (the worked
  example).

### P1 — Money, time, numbering (component CRC-1)

- Read: `billing-engine-spec` 01 (domain model, money primitives, time, numbering), `appendix-currencies.md`.
- Build: currency exponents, rounding (half away from zero, RBD-95), minor-unit conversion, fee tax rows,
  effective time zone, local-day counting with DST, termination-instant comparison, document prefixes, slugs,
  sequential ids, invoice and credit-note numbers, code reuse rules.
- Ops: `domain.*`.
- Gate: `kitrun.py --impl-cmd "$A" --areas domain` → domain 100 %, CORE 100 %.

### P2 — Pricing (CRC-2)

- Read: `billing-engine-spec` 05.
- Build: the charge-model pricing function for every model (standard, package, graduated, graduated percentage,
  volume, percentage incl. per-transaction min/max, dynamic, custom, prorated graduated, grouped wrapper) with its
  amount details; pay-in-advance delta pricing; fee money (cents, precise amounts, unit amounts); charge-minimum
  true-up; pricing units; fixed charges; property validation and defaults; projections, instant estimates and the
  simulator.
- Ops: `pricing.*`. Gate: `--areas pricing` → ≥ 98 %, CORE 100 %.

### P3 — Expression language and aggregation (CRC-3, CRC-4)

- Read: `billing-engine-spec` 02, 03, 04.
- Build: event timestamp parsing and validation, idempotency keys per store, the raw message, the expression
  evaluator (grammar, typing, rounding functions, errors), then aggregation per type (count, sum, max, latest,
  unique count, weighted sum, custom) with filters, grouping, recurring carry-over, proration, pay-in-advance running
  state and current-usage views. PostgreSQL-store semantics are normative; the ClickHouse variant is optional
  (`store-ch` vectors).
- Ops: `events.*`, `expression.*`, `aggregation.*`.
- Gate: `--areas events,expression` → ≥ 98 %; `--areas aggregation` → ≥ 95 %; CORE 100 %.

### P4 — Subscriptions and billing periods (CRC-5)

- Read: `billing-engine-spec` 06.
- Build: the period algebra per interval (weekly, monthly, quarterly, semiannual, yearly) × billing time (calendar,
  anniversary) with month-end clamping, the billing-day predicate, subscription-fee amounts (proration, trials,
  upgrades, terminations), plan-change classification, lifecycle helpers.
- Ops: `periods.*`. Gate: `--areas periods` → ≥ 98 %.

### P5 — Invoices, taxes, coupons, credit notes (CRC-6)

- Read: `billing-engine-spec` 07, 08.
- Build: the invoice totals pipeline in its normative order, tax selection and rounding (invoice tax from unrounded
  per-fee contributions), coupon amount/order/distribution/consumption, invoice status and dates (grace period,
  zero-amount rule), credit notes (items, coupon adjustment, taxes, credit/refund/offset split, residue rules).
- Ops: `invoice.*`, `credit_notes.*`. Gate: each area ≥ 95 %.

### P6 — Wallets, progressive billing, alerts (CRC-7)

- Read: `billing-engine-spec` 09, 10.
- Build: credit ↔ money conversion, top-up rules, prepaid allocation and consumption order, ongoing balance,
  progressive-billing thresholds and credits, alert crossing and measurement.
- Ops: `wallets.*`, `progressive.*`, `alerts.*`. Gate: each area ≥ 95 %.

### P7 — REST API, webhooks, clock (CRC-8)

- Read: `billing-engine-spec` 11, 12, 13, 14.
- Build: API conventions (envelopes, errors, pagination), the resources in scope, webhook payload envelope, the exact
  body encoding, HMAC and RS256 JWT signing (the kit ships a test-only key for deterministic vectors), event-type
  filters, retry schedule, clock jobs and idempotency keys.
- Ops: `api.*`, `webhooks.*`, `clock.*`. Gate: each area 100 %.

### P8 — Events-processor (CRC-9)

- Read: `events-processor-spec` (contract, wire formats, processing rules, delivery and failures, memory-cache mode,
  conformance suite). Production runs memory-cache mode; DB mode is the development fallback; both are graded.
- Build: the consumer, per-record pipeline, delivery semantics of the chosen profile (compat commit behaviour or the
  corrected ADR-001 dispositions), outputs and refresh flag.
- Gates: `kitrun.py --impl-cmd "$A" --areas ep` → ≥ 95 %; `events-processor-spec/scripts/run-suite.sh --impl-cmd
  "<consumer>" --profile both --loose-errors` → corrected: 100 % of decided assertions; compat: ≥ 90 % of DB goldens;
  startup contract EPC-26..EPC-29 4/4.

### P9 — Scenario tier (CRC-10, stretch)

- Read: `scenario-tier.md`, `billing-engine-spec` scenarios `MANIFEST.md`.
- Build: wire the components behind the five `system.*` ops (or the HTTP bridge with test-only clock endpoints).
- Gate: `scripts/scenario-replay.py` ≥ 60 % (stretch target; 100 % is the long-term bar).

## 5. Dependency graph of the phases

```
P0 ─► P1 ─┬─► P2 ─────────────┐
          ├─► P3 (needs P1) ──┼─► P5 (needs P2, P4) ─► P6 ─► P7 ─► P9
          └─► P4 (needs P1) ──┘
P0 ─► P8 (independent of P2-P7; shares the expression language with P3)
```

P2, P3 and P4 can run in parallel teams once P1 is green. P8 can start any time after P0.

## 6. Working loop per phase

1. Read the chapter end to end, then its "Edge cases" section.
2. Implement one rule at a time; run `kitrun.py --only '<id prefix>'` for the vectors listed in its `[vec: …]`.
3. When a vector fails, read the diff line (`path: expected X (mode) got Y`), then the rule. If the rule does not
   explain the expected value, log a kit gap (question, where you looked, your assumption) — do not reverse-engineer
   the value from the vector alone.
4. Keep a regression run of all finished areas (`kitrun.py --areas <done areas> --quiet`).
5. A phase is done when its gate passes on a clean checkout of the implementation.

## 7. Traps that cost the most time

| Trap | Where the kit pins it |
|---|---|
| Using binary floats for money or units | `vector-format.md` §3; `float-island` vectors are the only exceptions (compat profile) |
| Rounding half-to-even (banker's) instead of half away from zero, especially for negatives | RBD-95 vectors in `domain.*` |
| Counting days in UTC instead of the customer's local calendar (DST months are 30/31 days, not 30.96) | `domain.days_between` vectors tagged `dst` |
| Ordering by timestamp without a tie-break (the reference leaves equal timestamps undefined) | RBD-30; vectors avoid ties or `ignore` the order |
| Treating JSON numbers in event payloads as floats (spelling and precision change) | `literal` vectors, `*_json` inputs |
| Reading the wall clock in a computation | TIME-2; every op takes its instant |
| Summing rounded per-fee taxes for the invoice tax | RBD-69 vectors in `invoice.*` and `domain.fee_taxes` |
| Assuming the ClickHouse store behaves like the PostgreSQL store | RBD-25..RBD-31, `store-ch` vectors |

## 8. Definition of done for a rebuild

All phase gates green on the shipped vectors, the maintainer-run holdout within the thresholds of
`acceptance-and-grading.md` §2, zero open kit-vector defects, and the gap log triaged.

## Provenance (maintainers)

- Phase list and gates: kit plan of record (2026-10-02) sections 1.2, 7.1; thresholds mirrored in
  `acceptance/thresholds.json`.
- Gate commands verified on 2026-10-02 against the kit's own tools: `bash scripts/kit-selftest.sh` and
  `kitrun.py --impl-cmd "python3 scripts/adapter_ref.py" --vectors selftest/domain.selftest.jsonl --only round`
  → `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=14 passed=14 skipped_ops=0 exit=0`.
- Update triggers: a phase gate threshold change, a new area or component, a chapter renumbering.
