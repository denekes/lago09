---
name: billing-engine-spec
description: "Behaviour spec of the in-scope Lago billing engine (lago-api at pin 591ae90) for a clean-room rebuild, with golden vectors per area: domain model, money and time rules, event ingestion, expression language, aggregation with relational vs columnar store variants, charge models and fees, billing periods and proration, invoices, taxes, coupons, credit notes, wallets, progressive billing, alerts, REST API v1, webhooks and signing, clock. Use to implement, port or verify billing logic, or to ask what the engine computes for given inputs. Not for glossary or code locations (use domain-reference)."
---
# Billing engine spec: what the Lago billing core computes

> Licence note: this skill describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (v1.53.0,
> 2026-09-08) in neutral form, with behavioural test data; no reference source is reproduced. Read
> `reimplementation-kit/reference/legal-and-provenance.md` before a proprietary rebuild (legal review recommended).

Language-neutral specification of the billing core of Lago — catalogue, customers, event ingestion, usage
aggregation, pricing, billing periods, invoices, taxes, coupons, credit notes, wallets, progressive billing, alerts,
the REST API v1 surface, webhooks and the clock — written so that a team holding only the kit can build an
equivalent engine and prove it with the kit's vectors. Facts as of lago-api `591ae9005110`; kit v1.6.0.
Scope IN: the items above. Scope OUT (interface boundary only, chapter 14): payment providers, tax providers,
accounting/CRM integrations, e-invoicing, documents and e-mail, dunning, the newer quote/contract features,
entitlements, GraphQL administration, authentication of members, analytics and data exports.

## 1. When to use / when NOT to use

Use this skill to:
- implement, port or re-platform any part of the billing core and know exactly what it must compute;
- answer "what does the engine bill/return for these inputs?" from a rule plus the vectors that pin it;
- find the vectors and scenarios that grade an area, and run them against an implementation;
- check whether a reference behaviour is a quirk with a rebuild decision (`RBD-n`).

Do NOT use it for:
- the rebuild method, vector format, adapter protocol, runners, grading or the RBD table → `reimplementation-kit`;
- the Go events-processor (wire formats, delivery, black-box suite) → `events-processor-spec`;
- the Lago glossary and where things live in this repository's code → `domain-reference`;
- Go/Rails contract drift in this repository → `rails-go-parity`; changing the Go code → `architecture-contract`.

## 2. Start here (reading order)

<!-- evidence-check: off reading order (navigation), not claims -->

1. `reimplementation-kit` SKILL.md sections 4-7: phases, profiles (`compat` vs `corrected`), vectors, kitrun.
2. Section 3 below (conventions), then chapter 01 with `appendix-currencies.md`, `appendix-enums.md`, `glossary.md`.
3. The chapter of the phase you build (section 5 map), always with its vectors open next to it: a rule line ends with
   `[vec: …]`, and each vector's `rules` array points back.
4. Section 6 (the rules people get wrong) before the first kitrun of an area.
5. `reimplementation-kit/reference/rebuild-decisions.md` for every `RBD-n` a chapter cites.
6. Last: the scenario tier (section 9) once the unit areas pass.

<!-- evidence-check: on -->

## 3. Conventions shared by every chapter

<!-- evidence-check: off normative spec; evidence = the rule ids cited per row, whose rule lines list their vectors -->

| Topic | Convention |
|---|---|
| Money | minor units (`*_cents`) as integers; a currency's exponent and minor units per major unit come from `appendix-currencies.md` (142 codes; HUF 0, MRO 1 with 5 minor units); precise companions (`precise_*`) keep the unrounded value |
| Decimals | exact decimal arithmetic; decimal strings on the wire (`"1.50"` = `"1.5"`); no binary floating point except the documented float islands (RBD-96) |
| Rounding | half away from zero everywhere, negatives included (BE-DM-23, RBD-95); `unit_amount_cents` is truncated (BE-PR-54) |
| Instants | UTC with microsecond precision in the relational store; API renders whole seconds except five documented fields (RBD-87) |
| Time zone | effective zone = customer's, else billing entity's, else UTC (BE-DM-10); local dates are derived at use time, except the invoice, which snapshots its zone (BE-DM-13) |
| Days | DST-aware whole local days, `+1 s` when a period ends at local midnight, `-1` day for a period ended by an upgrade (BE-DM-15..18) |
| Intervals | billing and usage windows are closed `[from, to]` with `to` = `…:59.999999` local; an event exactly on a shared boundary belongs to both windows (BE-AG-6, RBD-35) |
| Clock | hourly runs evaluate customer-local dates; equivalence is judged per local day (RBD-94); every time-dependent op takes an explicit instant |
| Tenancy | everything is scoped to one organization; codes and external ids are unique per organization (BE-DM-1, BE-DM-50..55) |
| Premium | premium-gated behaviour is an explicit `premium` input flag (BE-IF-11, RBD-97) |
| Store | the relational event store is normative; the columnar store is a variant (section 7) |

<!-- evidence-check: on -->

## 4. Engine architecture (data flow)

```
 REST /api/v1/events ──► ingestion (02: validate, idempotency, expression 03) ──► event store (relational | columnar)
                                   │                                                   │ (columnar fed through the
                                   └─► raw topic ──► events-processor (separate spec) ─┘  events-processor)
 catalogue + customers + subscriptions (01, 05, 06) ─────────────┐
 clock (13): hourly billing run, finalization, top-ups, alerts ──┤
                                                                 ▼
 periods (06) ──► aggregation per charge/filter/group (04) ──► pricing per charge model (05) ──► fees
                                                                                                │
 invoice pipeline (07): progressive credits ─► coupons ─► taxes ─► credit notes (08) ─► wallets (09) ─► totals
                                                                                                │
 progressive billing and alerts (10) ◄── lifetime / current usage                               ▼
                                                     webhooks (12) ◄── state changes ── REST API v1 (11)
```

Pay-in-advance charges skip the period path: each event is priced at ingestion time by delta pricing (BE-PR-43..50)
and billed on its own invoice or fee. The scenario tier drives the whole engine through `system.*` ops (section 9).

## 5. Chapter map

| Chapter | Rules | Vector files | Read when |
|---|---|---|---|
| `reference/01-domain-model.md` | BE-DM-1..66 (61) | `domain.time`, `domain.money`, `domain.numbering`, `domain.catalog` | always first: entities, settings inheritance, time, money, numbering, codes, status machines |
| `reference/02-events-ingestion.md` | BE-EV-1..74 (46) | `events.ingest` | building `POST /events` and `/events/batch`: timestamp grammar, validation order, idempotency per store, raw message |
| `reference/03-expression-language.md` | BE-EX-1..51 (27) | `expression` | metric expressions: grammar, values, division, rounding functions, three surfaces |
| `reference/04-aggregation-and-usage.md` | BE-AG-1..74 (59) | `aggregation.core`, `.filters`, `.in_advance`, `.prorated`, `.store_ch` | usage for a window: selection, numeric gate, six aggregation types, filters and groups, in-advance state, proration, columnar variant |
| `reference/05-pricing-and-fees.md` | BE-PR-1..88 (88) | `pricing.models`, `.in_advance`, `.fees`, `.validation`, `.fixed_charges`, `.misc` | charge models, delta pricing, fee money, true-up, pricing units, fixed charges, validation |
| `reference/06-subscriptions-and-periods.md` | BE-SP-1..66 (66) | `periods.boundaries`, `.billing_days`, `.chains`, `.subscription_fee`, `.lifecycle` | period algebra, billing-run boundaries, scheduling, subscription fee, lifecycle, plan changes, trials |
| `reference/07-invoices-taxes-coupons.md` | BE-IV-1..58 (58) | `invoice.totals`, `.taxes`, `.coupons`, `.lifecycle`, `.commitment` | invoice types, totals pipeline, taxes, coupons, lifecycle, void, minimum commitment |
| `reference/08-credit-notes.md` | BE-CN-1..24 (24) | `credit_notes` | credit, refund and offset notes, rounding correction, estimate, termination notes |
| `reference/09-wallets.md` | BE-WL-1..62 (43) | `wallets` | prepaid credits, transactions, top-up rules, allocation to invoices, ongoing balance |
| `reference/10-progressive-billing-and-alerts.md` | BE-PB-1..24 (21), BE-AL-1..12 (12) | `progressive`, `alerts` | lifetime usage, usage thresholds, progressive credits, alert measures and crossings |
| `reference/11-rest-api.md` | BE-API-1..36 (36) | `api` | auth, errors, pagination, endpoint table, response field catalogue with JSON types |
| `reference/12-webhooks.md` | BE-WH-1..29 (29) | `webhooks` | endpoints and filters, catalogue, payload envelope, exact body bytes, HMAC and RS256 JWT, retries |
| `reference/13-clock-and-async.md` | BE-CK-1..12 (12) | `clock` | job schedule and deployment gates, local days, termination alerts, idempotency keys |
| `reference/14-out-of-scope-interfaces.md` | BE-IF-1..12 (12, prose only) | — | what the core emits to and accepts from payments, tax providers, integrations, documents, licensing |

Every chapter has an AGPL note, numbered rules each ending in `[vec: …]` (or a prose-only marker with a reason), an
edge-case table, a vector table and a maintainer Provenance section. Rule coverage on 2026-10-05: every BE rule has a
vector or a prose-only marker (`validate-vectors.py --rule-coverage`, section 11).

## 6. The 32 rules people get wrong

Each line: the rule, the trap, the vectors that catch it (all EXECUTED against the reference unless marked `x`).

<!-- evidence-check: off normative spec; evidence = the vector ids at the end of each line (EXECUTED at the pin unless the id ends in x) -->

1. **BE-DM-23** Rounding is half away from zero on exact decimals, negatives included: −0.125 EUR → −13 cents, 0.135 is a tie, 1.005 at two places → 1.01 (never half-even, never binary float). [vec: domain.money.to_minor_units.003, domain.money.to_minor_units.004, domain.money.round.001]
2. **BE-DM-28** A fee's tax is the rounded sum of its UNROUNDED tax rows: two 10 % taxes on 15 cents give rows 2 + 2 but a fee tax of 3. [vec: domain.money.fee_taxes.001, domain.money.fee_taxes.005]
3. **BE-DM-16** A period ending exactly at local midnight counts the day that starts there (a zero-length period at midnight counts 1). [vec: domain.time.days_between.003]
4. **BE-EV-12/13** A non-integer JSON-number timestamp is read through binary64 first; the stored time is truncated (not rounded) to microseconds, while the raw message carries the binary64 seconds. [vec: events.parse_timestamp.009, events.parse_timestamp.010, events.raw_message.003]
5. **BE-EV-23/41** The columnar store validates nothing for a single event, yet checks presence for batch events (RBD-32). [vec: events.validate.019, events.validate_batch.016]
6. **BE-EX-10** String literals in an expression are never numbers: `greatest('9', 7)` fails, while a numeric property string converts on use. [vec: expression.values.010]
7. **BE-AG-5** The relational numeric gate drops non-numeric values from the COUNT as well as the value (`"1e3"`, `"+5"`, `".5"` are dropped). [vec: aggregation.core.sum.005, aggregation.core.sum.008]
8. **BE-AG-12/13** `latest` reports a negative last value as 0, while `max` over negative values stays negative (RBD-39). [vec: aggregation.core.latest.002, aggregation.core.max.003]
9. **BE-AG-15** Unique-count identity is the stored property text: `1` and `"1"` are one value, `1.0` is another. [vec: aggregation.core.unique.007]
10. **BE-AG-6** An event exactly at an upgrade instant is counted by both the old and the new subscription (RBD-35, corrected proposal: new only). [vec: aggregation.core.window.001, aggregation.core.window.002]
11. **BE-PR-16** At zero usage the first tier's flat amount is still billed (graduated, graduated percentage, volume; RBD-48). [vec: pricing.graduated.001, pricing.volume.001, pricing.gp.001]
12. **BE-PR-54** `unit_amount_cents` is truncated (0.0199 EUR → 1 cent) while `amount_cents` rounds half away (RBD-47). [vec: pricing.fee_money.001, pricing.fee_money.007]
13. **BE-PR-23** Volume picks the tier by `ceil(N)`: 100.5 units fall into the tier starting at 101 (RBD-49). [vec: pricing.volume.003, pricing.volume.011]
14. **BE-SP-6** Month-end anniversary anchors re-clamp from the anchor day every period and never drift (31st → Feb 28 → Mar 31; RBD-64). [vec: periods.boundaries.base.001, periods.billing_days.monthly.001, periods.chain.001]
15. **BE-SP-19** The first subscription fee counts the whole local start day while usage counts from the exact start instant (RBD-56). [vec: periods.boundaries.clamp.001]
16. **BE-SP-27/34** A termination within 24 h after a period end bills the previous full period, and the periodic run skips the subscription on its local ending day; implement both or bill twice (RBD-63). [vec: periods.invoice_boundaries.001, periods.periodic_billing.004]
17. **BE-IV-13** Invoice tax = round(Σ unrounded per-code contributions): it differs from the sum of rounded fee taxes (four 1-cent fees at 40 %: fee taxes 0, invoice tax 2) and from the sum of rounded rows (RBD-69). [vec: invoice.totals.016, invoice.totals.001]
18. **BE-IV-6** A draft (grace period) gets no coupon, credit-note credit or prepaid credit; they apply only at finalization, so the total can drop then (RBD-71). [vec: invoice.totals.005]
19. **BE-IV-34** The zero-amount rule tests the fees amount, not the total: a fully discounted invoice is still finalized (RBD-70). [vec: invoice.final_status.003]
20. **BE-CN-9** The last credit note of an invoice absorbs the tax rounding residue of the earlier ones; per-code rows are not adjusted (RBD-75). [vec: credit_notes.compute.002]
21. **BE-WL-2** Invoiceable wallet credits snap to whole minor units: 1034 credits at 0.001 EUR become 1030 (RBD-81). [vec: wallets.credits.001]
22. **BE-PB-2** Lifetime "invoiced" usage counts charge fees of DRAFT subscription invoices too (RBD-76). [vec: progressive.lifetime_usage.002]
23. **BE-AL-3** Metric alerts measure the LARGEST matching fee, not the sum, so a metric split by filters is measured by its largest bucket (RBD-77, corrected proposal: sum). [vec: alerts.measure.002, alerts.measure.002x]
24. **BE-API-21** `per_page` absent means 100, but a non-numeric or negative `per_page` means 25 (and `per_page=0` with records fails, RBD-86). [vec: api.pagination_meta.006, api.pagination_meta.007]
25. **BE-WH-12/14** Sign the exact body bytes as sent: `<` `>` `&` are escaped as `\u003c` `\u003e` `\u0026`, non-ASCII stays raw, floats follow the shortest-digits rule (RBD-84); re-serialising a parsed body breaks the HMAC. [vec: webhooks.encode.001, webhooks.sign.002]
26. **BE-DM-15** The day count adds `offset(to) − offset(from)` to the elapsed time (the wall-clock duration), not the reverse: across the New York spring change an elapsed 29 d 23:30 is a wall-clock 30 d 00:30 and counts 31 days. [vec: domain.time.days_between.006, domain.time.days_between.013]
27. **BE-SP-38** Proration is `days × (amount ÷ length)` with the quotient rounded to binary64 first, never `(days × amount) ÷ length`: 21 × (34 ÷ 28) = 25.499999999999996 → 25 cents. [vec: periods.subscription_fee.034, periods.termination_credit_days.009]
28. **BE-PR-87** Every fee (in-advance and fixed-charge in-advance included) stores its precise amounts rounded half away at 15 decimal places, and fixed-charge units at 10 places, before anything else reads them. [vec: pricing.fee_money.022, pricing.in_advance.040, pricing.fixed_charge_in_advance.007]
29. **BE-EX-15** A zero subtrahend returns the minuend as written: `5 - 0.00` is `5` (not `5.00`). [vec: expression.text.009]
30. **BE-AG-56** In-advance proration cuts the binary64 ratio to 16 digits while the period aggregation keeps all 17 of its shortest text: 28 × 5/28 gives 5 in advance and 5.00001 for the period. [vec: aggregation.prorated.in_advance.006, aggregation.prorated.island.004]
31. **BE-IV-23 vs BE-IV-11** 17.5 % of 180 cents is 31 as an unlimited coupon (rate divided first, binary64 product), 32 as a metric- or plan-limited coupon (exact product of a decimal base) and 32 as a tax (exact product divided by 100 last). [vec: invoice.coupon_amount.010, invoice.coupon_distribution.013, invoice.apply_taxes.011]
32. **BE-CN-8 vs BE-IV-14** The credit note's tax rate is decimal (7/160 × 5.5 → 0.24063) while the invoice's is binary64 (0.24062). [vec: credit_notes.compute.018, invoice.apply_taxes.003]

<!-- evidence-check: on -->

More traps live in each chapter's edge-case table and in `reimplementation-kit/reference/method.md` section 7.

## 7. Store variants (relational normative, columnar variant)

The relational (PostgreSQL) event store is normative. The columnar (ClickHouse) store, fed by the events-processor's
enriched records, is a documented variant: its vectors carry `store: "ch"` and the tag `store-ch`, run in the compat
profile, and their corrected twins expect the relational result (proposed, RBD-25..RBD-31; the owner allowed the
columnar schema changes this needs). Which store a tenant uses is fixed at organization creation (chapter 02).

<!-- evidence-check: off normative spec; evidence = the rule and RBD ids per row and the aggregation.store_ch / events vectors they cite -->

| Topic | Relational store (normative) | Columnar store (variant) | Rule / decision |
|---|---|---|---|
| Numeric gate | non-numeric or missing values dropped from value and count | no gate: they count as events worth 0; exponent forms, `+5`, `.5`, `5.` are numbers | BE-AG-5, BE-AG-60, RBD-25 |
| Large values | exact (numeric(40,15)) | magnitude ≥ 10¹² reads as 0 | BE-AG-61, RBD-26 |
| Unique identity, filters, groups | stored JSON text (`1` = `"1"` ≠ `1.0`) | events-processor value text (`1` = `"1"` = `1.0`; `1e+06` ≠ `"1000000"`); missing key reads `""` | BE-AG-15, BE-AG-62, BE-AG-69, RBD-27 |
| Unknown `operation_type` | removal never a no-op first: totals can go negative | different counting | BE-AG-16, BE-AG-63, RBD-28 |
| Weighted-sum durations | exact fractional seconds | whole-second boundaries crossed | BE-AG-17, BE-AG-64, RBD-29 |
| Ties | `latest` by ingestion order | no tie-break; in-advance boundary ties by `transaction_id` text | BE-AG-65, BE-AG-73, RBD-30 |
| Prorated unique count | grouped variant adds a phantom day | grouped = ungrouped | BE-AG-52, BE-AG-66, RBD-31 |
| Prorated sums | decimal day ratio q (20 places) and 17-digit carried ratio, then ceil₅ | binary64 products and sums inside the store, ceil₅ of their decimal texts (31 × 15/31 → 15, relational 15.00001) | BE-AG-56, BE-AG-74, RBD-96 |
| Time precision | microseconds | milliseconds | BE-AG-67, RBD-40 |
| Ingestion idempotency | per (organization, subscription, `transaction_id`) | none at ingestion; query-time de-duplication behind an organization flag | BE-EV-30..33, BE-AG-68, RBD-32 |

<!-- evidence-check: on -->

## 8. Out-of-scope boundaries

Chapter 14 fixes what the core emits and accepts at each boundary so a rebuild can stub it: payment providers
(payment requests, refunds, payment-status updates), payment-gated activation, tax providers (pending and failed
tax states), VIES checks and e-invoicing, accounting/CRM sync, PDF/XML documents (asynchronous, `file_url` null until
ready), e-mail, dunning, the newer quote/contract features and entitlements, administration and licensing, and the
infrastructure contract (relational database, optional columnar store, object storage for webhook payloads, caches).
Nothing there is graded by unit vectors.

## 9. Vectors and scenarios

Unit vectors (`vectors/*.jsonl`, format `reimplementation-kit/reference/vector-format.md`; counts on 2026-10-05 from
`python3 reimplementation-kit/scripts/validate-vectors.py --inventory --quiet`, shipped plus the maintainers' holdout,
both/compat/corrected; every both/compat vector EXECUTED through the oracle at the pin):

<!-- evidence-check: off measured inventory of 2026-10-05; evidence = the validate-vectors.py --inventory run named in the line above -->

| File | Ops | Vectors | b/c/x |
|---|---|---|---|
| `domain.time.jsonl` | applicable_settings, days_between, effective_timezone, terminated_at_reached, to_local | 41 | 41/0/0 |
| `domain.money.jsonl` | currency_exponent, fee_taxes, round, to_minor_units | 34 | 34/0/0 |
| `domain.numbering.jsonl` | credit_note_number, customer_slug, document_prefix, invoice_number, next_sequential_id | 45 | 45/0/0 |
| `domain.catalog.jsonl` | charge_filter_code, code_reusable, subscription_external_id_valid | 33 | 31/1/1 |
| `events.ingest.jsonl` | duplicate_key, parse_timestamp, raw_message, validate, validate_batch | 87 | 72/7/8 |
| `expression.jsonl` | evaluate (surfaces `rails`, `ep`, `preview`) | 107 | 103/1/3 |
| `aggregation.core.jsonl` | aggregate | 105 | 100/3/2 |
| `aggregation.filters.jsonl` | event_filter, group_keys, matching_and_ignored, select_events | 38 | 32/3/3 |
| `aggregation.in_advance.jsonl` | aggregate, current_usage_in_advance, in_advance_units | 35 | 27/5/3 |
| `aggregation.prorated.jsonl` | aggregate, in_advance_units | 49 | 33/8/8 |
| `aggregation.store_ch.jsonl` | aggregate, group_keys, select_events (columnar) | 61 | 19/22/20 |
| `pricing.models.jsonl` | charge_model | 112 | 94/9/9 |
| `pricing.in_advance.jsonl` | pay_in_advance | 43 | 37/3/3 |
| `pricing.fees.jsonl` | fee_money, pricing_unit, true_up | 47 | 33/7/7 |
| `pricing.validation.jsonl` | default_properties, filter_properties, validate_charge, validate_properties | 100 | 100/0/0 |
| `pricing.fixed_charges.jsonl` | fixed_charge_fee, fixed_charge_in_advance, fixed_charge_units | 27 | 21/3/3 |
| `pricing.misc.jsonl` | estimate_instant, projection, simulate | 28 | 19/5/4 |
| `periods.boundaries.jsonl` | boundaries, invoice_boundaries | 123 | 111/6/6 |
| `periods.billing_days.jsonl` | billing_days, periodic_billing | 34 | 32/1/1 |
| `periods.chains.jsonl` | chain | 8 | 8/0/0 |
| `periods.subscription_fee.jsonl` | single_day_price, subscription_fee | 58 | 46/6/6 |
| `periods.lifecycle.jsonl` | classify_change, create_status, terminate, termination_credit_days, trial_end | 41 | 33/4/4 |
| `invoice.totals.jsonl` | totals | 28 | 28/0/0 |
| `invoice.taxes.jsonl` | apply_taxes, fee_tax_selection | 23 | 21/1/1 |
| `invoice.coupons.jsonl` | coupon_amount, coupon_apply, coupon_create, coupon_distribution, coupon_order | 63 | 61/1/1 |
| `invoice.lifecycle.jsonl` | available_to_credit, final_status, issuing_date, payment_due_date, void | 60 | 48/6/6 |
| `invoice.commitment.jsonl` | commitment_true_up | 11 | 9/1/1 |
| `credit_notes.jsonl` | compute, estimate, termination, validate | 62 | 48/7/7 |
| `wallets.jsonl` | allocate, consumption_order, credits, interval_due, ongoing_balance, threshold_top_up, top_up, topup_amount | 99 | 96/1/2 |
| `progressive.jsonl` | check_thresholds, lifetime_usage, passed_amount, to_credit | 57 | 57/0/0 |
| `alerts.jsonl` | crossed, measure | 32 | 24/4/4 |
| `api.jsonl` | auth_token, authorize, count_cache_key, error_body, pagination_meta | 46 | 42/2/2 |
| `webhooks.jsonl` | encode, endpoint_receives, normalize_event_types, payload_envelope, public_key, retry_step, sign, type_info | 63 | 61/1/1 |
| `clock.jsonl` | idempotency_key, jobs_due, termination_alert_due | 20 | 18/1/1 |
| total | 105 unit ops | 1,820 | 1,584/119/117 |

<!-- evidence-check: on -->

Corrected twins (`…x`) are RECOMPUTED from their rebuild decision; all 117 of them are `ruling: proposed` (UNRULED
until the owner rules). Three test-only vectors carry the kit's test RSA key (tag `test-key`); never use it elsewhere.

Scenario tier: 76 end-to-end scenarios in `scenarios/scn.*.json` (index `scenarios/MANIFEST.md`): a tenant set up
over REST v1, a frozen clock moved step by step, events and API calls, named clock jobs, and a final (sometimes
intermediate) snapshot of invoices, fees, taxes, credit notes, wallets, transactions and subscriptions compared with
the reference. Every scenario was replayed twice on the reference and mutation-checked (EXECUTED). Five are `core`
(100 % required): `scn.invoice.taxes.001`, `scn.invoice.void.001`, `scn.credit_note.termination.004`,
`scn.subscription.billing.001`, `scn.usage.standard.001`. Format, replay semantics, tick vocabulary and grading:
`reimplementation-kit/reference/scenario-tier.md`.

## 10. Running the vectors per area

```bash
K=.claude/skills/reimplementation-kit
python3 $K/scripts/kitrun.py --impl-cmd "<your adapter>" --areas domain                 # phase P1
python3 $K/scripts/kitrun.py --impl-cmd "<your adapter>" --areas pricing                # P2
python3 $K/scripts/kitrun.py --impl-cmd "<your adapter>" --areas events,expression,aggregation   # P3
python3 $K/scripts/kitrun.py --impl-cmd "<your adapter>" --areas periods                # P4
python3 $K/scripts/kitrun.py --impl-cmd "<your adapter>" --areas invoice,credit_notes   # P5
python3 $K/scripts/kitrun.py --impl-cmd "<your adapter>" --areas wallets,progressive,alerts   # P6
python3 $K/scripts/kitrun.py --impl-cmd "<your adapter>" --areas api,webhooks,clock     # P7
python3 $K/scripts/kitrun.py --impl-cmd "<your adapter>" --areas pricing --profile corrected --quiet
python3 $K/scripts/scenario-replay.py --impl-cmd "<your system adapter>"                # P9, scenario tier
```

<!-- evidence-check: off procedure and thresholds; commands in the code block above, thresholds = reimplementation-kit/acceptance/thresholds.json -->

- The adapter answers the ops of `reimplementation-kit/schemas/ops/<area>.<op>.schema.json` over the JSON-lines
  protocol (`reimplementation-kit/reference/adapter-protocol.md`); unimplemented ops answer `unsupported_op` and
  count as SKIP.
- Thresholds per area (shipped / holdout / core): domain 100/98/100 %, pricing, events, expression and periods
  98/95/100 %, aggregation, invoice, credit_notes, wallets, progressive and alerts 95/90/100 %, api, webhooks and clock
  100/98/100 %, scenarios ≥ 60 % plus the five core scenarios (`reimplementation-kit/acceptance/thresholds.json`).
- A failing vector: read its first diff path, find the rule ids in its `rules` array, re-read those rule lines; group
  failures by op and first diff path. Triage tree: `reimplementation-kit` SKILL.md section 9.
- Profiles: `--profile compat` grades `both` + `compat` vectors (migration); `--profile corrected` grades `both` +
  `corrected` and shows `proposed` twins as UNRULED (greenfield).

<!-- evidence-check: on -->

## 11. Scripts

This skill ships data and text only; it uses the kit's tooling:

| Command (from the skills root) | Purpose | Observed (2026-10-05) |
|---|---|---|
| `python3 reimplementation-kit/scripts/validate-vectors.py billing-engine-spec/vectors/*.jsonl` | format, evidence, content checks of these vectors | 0 errors |
| `python3 reimplementation-kit/scripts/validate-vectors.py --rule-coverage --quiet \| grep 'COVERAGE billing'` | per chapter: rules with vectors, prose-only, uncovered | 14 chapters, `uncovered=0 holdout_only=0` each |
| `python3 reimplementation-kit/scripts/validate-vectors.py --inventory --quiet` | per-file counts and evidence mix | every both/compat billing vector EXECUTED (1,681 of 1,681, holdout included) |
| `python3 reimplementation-kit/scripts/kitrun.py --impl-cmd CMD --areas …` | grade an implementation | section 10 |
| `python3 reimplementation-kit/scripts/scenario-replay.py --impl-cmd CMD` | grade the scenario tier | `reimplementation-kit/reference/scenario-tier.md` §10 |

## 12. Provenance and maintenance (maintainers)

- Pin: lago-api `591ae9005110` (v1.53.0), checked out read-only with `research-methodology/scripts/pinned-checkout.sh
  api`. Every vector records its pin, runtime and run date; reference locations (`$API/<path>:<line>`) appear only in
  each chapter's "Provenance (maintainers)" section and in `evidence.ref`.
- Minting: both/compat vectors were EXECUTED through the oracle adapter (lago-api code at the pin answering the adapter
  protocol, `reimplementation-kit/reference/maintainer-oracle.md`); expression vectors of the processor surface ran on
  the events-processor's engine build; scenarios were recorded from green reference examples, converted to the kit
  form and replayed twice on the reference; corrected twins were recomputed from their rebuild decision.
- Re-verification one-liners (maintainers, own database per person, `-j 1`):
  - one area against the reference: `ORACLE_DB=lago_api_test_<you> python3 reimplementation-kit/scripts/kitrun.py
    --impl-cmd "reimplementation-kit/scripts/maintainer/oracle.sh adapter" --areas <area>` → every both/compat vector
    PASS, corrected `proposed` twins UNRULED (2026-10-05, all 14 areas with `--include-holdout
    reimplementation-kit/maintainer-data/holdout`: `SUMMARY kitrun: areas=28 pass=28 fail=0 vectors=1681 passed=1681`,
    which covers every both/compat vector of section 6 and every one cited by id in `rebuild-decisions.md`);
  - evidence references: `python3 reimplementation-kit/scripts/maintainer/vector-provenance.py` → `broken=0`;
  - scenarios: `reimplementation-kit/scripts/maintainer/replay-on-lago.sh` (two replays + mutation, all ACCEPT);
  - rule coverage: `python3 reimplementation-kit/scripts/validate-vectors.py --rule-coverage --quiet` → `uncovered=0`
    in every chapter (2026-10-05).
- Update triggers: a lago-api pin bump (re-mint every vector and scenario through the oracle and triage the diffs as
  behaviour change or kit defect), a runtime or decimal-library change of the oracle (re-mint the float-island
  vectors), an owner ruling on an RBD (flip the twins' `ruling`; `reimplementation-kit/reference/rebuild-decisions.md`),
  a new rule or vector (keep the `[vec: …]` tag and the vector's `rules` array in step).
