---
name: reimplementation-kit
description: "Entry point of the clean-room re-implementation kit for the Lago events-processor and billing engine: rebuild method and build order, compat vs corrected profiles, rebuild decisions RBD-1..n, the golden-vector JSON format, the JSON-lines adapter protocol and kitrun.py, scenario replay, grading thresholds, clean-room and AGPL rules. Use to rebuild, re-platform, reimplement or port Lago, to run golden or conformance vectors against a new implementation, or to triage a failing vector. Not for the specs (use events-processor-spec, billing-engine-spec) or Go internals (use architecture-contract)."
---
# Re-implementation kit: method, vectors, protocol, grading

> Licence note: the kit describes the behaviour of lago-api (AGPL-3.0) and of the Lago events-processor in neutral
> form and ships behavioural test data; no reference source is reproduced. Read `reference/legal-and-provenance.md`
> before a proprietary rebuild (legal review recommended).

This skill is the entry point of a self-contained kit for rebuilding — in any language or architecture — a system
that behaves like the Lago billing engine (lago-api) and the Lago events-processor, and for proving it with
golden vectors. The behaviour itself lives in `billing-engine-spec` and `events-processor-spec`; this skill holds
the method, the vector format, the adapter protocol, the runners and the grading rules. Behaviour facts as of
lago-api `591ae90` (v1.53.0, 2026-09-08) and events-processor tree `83e012866f29`; kit v1.6.0, accepted on
2026-10-05 by twelve clean-room implementations after six fix rounds (changes in section 13).

## 1. When to use / when NOT to use

Use this skill to:
- plan a rebuild, re-platform or port of Lago (or of one component: pricing engine, billing periods, invoicing,
  events-processor) and pick the build order;
- run the golden vectors against a new implementation (`kitrun.py`) or the events-processor suite;
- write an adapter for an implementation, read a kitrun report, or triage a failing vector;
- add or change vectors, ops or schemas, or re-mint vectors after a pin bump (maintainers).

Do NOT use it for:
- what the billing engine computes (rules, formulas, edge cases) → `billing-engine-spec`;
- what the events-processor does on the wire → `events-processor-spec`;
- changing the Go events-processor in this repository → `architecture-contract`, `event-accounting-campaign`;
- the Lago glossary and code locations → `domain-reference`; Go/Rails contract drift → `rails-go-parity`.

## 2. Terms

<!-- evidence-check: off definitions of the terms, not claims; the op count is re-measured in section 12 -->

| Term | Meaning |
|---|---|
| reference | lago-api at pin `591ae9005110` and the events-processor at tree `83e012866f29` — the behaviour the kit records |
| rebuild / implementation | the system being built from the kit |
| area | a behaviour domain with its own vectors and threshold: `domain`, `events`, `expression`, `aggregation`, `pricing`, `periods`, `invoice`, `credit_notes`, `wallets`, `progressive`, `alerts`, `api`, `webhooks`, `clock`, `ep` (+ `scn` scenarios) |
| op | one gradable function of an area (`pricing.charge_model`); 116 ops on 2026-10-02 (111 unit-vector ops + 5 `system.*`), one JSON Schema each in `schemas/ops/` |
| vector | one input → expected output case for one op (JSON Lines); `vector-format.md` |
| scenario | an end-to-end case over the REST API and the clock (`scn.*`), replayed through `system.*` ops |
| adapter | the implementation's small stdin/stdout program answering ops (`adapter-protocol.md`) |
| oracle | the maintainers' adapter answering ops with the reference code at the pin (`scripts/maintainer/`) |
| profile | `compat` = reproduce the reference including its quirks; `corrected` = apply the rebuild decisions; a vector is `both`, `compat` or `corrected` |
| RBD | rebuild decision: a reference behaviour the corrected profile keeps or changes (`reference/rebuild-decisions.md`) |
| ruling | `decided` or `proposed` (owner has not ruled; graded as UNRULED, advisory) |
| evidence | how a vector's expected value was obtained: EXECUTED (reference ran), RECOMPUTED (independent model), EXTRACTED (read only) |
| core | vectors that must pass 100 % |
| holdout | 20 % of vectors kept by maintainers to detect overfitting; never in a clean-room pack |
| mode / store | events-processor DB vs memory-cache mode (production = memory-cache); event store PostgreSQL (normative) vs ClickHouse (variant) |
| KQ | an open question or risk of the kit (section 12) |

<!-- evidence-check: on -->

## 3. The kit at a glance

<!-- evidence-check: off kit layout and pack policy; enforced by kit-pack.sh --cleanroom and make-kit-json.py (section 11) -->

| Part | Where | Normative? | In a clean-room pack? |
|---|---|---|---|
| Method, format, protocol, grading, legal | this skill, `reference/*.md` | yes | yes (except `maintainer-oracle.md`) |
| Billing behaviour (14 chapters + appendices) | `billing-engine-spec/reference/` | yes | yes |
| Billing unit vectors | `billing-engine-spec/vectors/*.jsonl` | yes | yes (minus holdout) |
| Billing scenarios | `billing-engine-spec/scenarios/scn.*.json` | yes | yes |
| Events-processor behaviour + black-box suite | `events-processor-spec/` | yes | yes (minus `scripts/maintainer/`) |
| Schemas (envelope, protocol, report, scenario, 116 ops) | `schemas/` | yes | yes |
| Thresholds | `acceptance/thresholds.json` | yes | yes |
| Runners and helpers | `scripts/kitrun.py`, `kitlib.py`, `validate-vectors.py`, `adapter_ref.py`, `kit-selftest.sh` | tooling | yes |
| Runner fixtures | `selftest/domain.selftest.jsonl` (23 EXECUTED vectors) | examples | yes |
| Oracle, selftest adapter, provenance check, pack builder | `scripts/maintainer/` | maintainer tooling | **no** |
| Holdout vectors | `maintainer-data/holdout/` | grading data | **no** |
| Clean-room acceptance record (runs 1 to 6, verdict on 1.5.0) | `maintainer-data/acceptance-2026-10.md` | owner report | **no** |

<!-- evidence-check: on -->

Pins: lago-api `591ae9005110`; events-processor tree `83e012866f29`. Versions: adapter protocol `proto` 1, vector
envelope `kit_schema` 1, catalogue `kit_version` 1.6.0 (from `kit.json`; kitrun prints `1.6.0-dev` until it exists).

## 4. Rebuild method (summary of `reference/method.md`)

<!-- evidence-check: off normative build method; done-when thresholds = acceptance/thresholds.json, details in reference/method.md -->

| Phase | Build | Read | Done when |
|---|---|---|---|
| P0 | adapter skeleton, exact-decimal JSON, harness | this skill, `vector-format.md`, `adapter-protocol.md` | `kit-selftest.sh` fail=0; `domain.round` example 14/14 |
| P1 | money, rounding, time zones, day counting, numbering (CRC-1) | billing 01 + currencies | `kitrun --areas domain` 100 %, CORE 100 % |
| P2 | all charge models, pay-in-advance, fee money, true-up, pricing units, fixed charges, validation (CRC-2) | billing 05 | `--areas pricing` ≥ 98 % |
| P3 | event ingestion, expression language, aggregation with filters and grouping (CRC-3, CRC-4) | billing 02-04 | events/expression ≥ 98 %, aggregation ≥ 95 % |
| P4 | billing periods, subscription fees, lifecycle helpers (CRC-5) | billing 06 | `--areas periods` ≥ 98 % |
| P5 | invoice totals, taxes, coupons, credit notes (CRC-6) | billing 07-08 | invoice, credit_notes ≥ 95 % |
| P6 | wallets, progressive billing, alerts (CRC-7) | billing 09-10 | each ≥ 95 % |
| P7 | REST API, webhooks and signing, clock (CRC-8) | billing 11-14 | api, webhooks, clock 100 % |
| P8 | events-processor, DB and memory-cache modes (CRC-9) | `events-processor-spec` | `run-suite.sh` gates + `--areas ep` ≥ 95 % |
| P9 | scenario tier behind `system.*` (CRC-10, stretch) | `scenario-tier.md` | `scenario-replay.py` ≥ 60 % |

<!-- evidence-check: on -->

P2, P3 and P4 can proceed in parallel after P1; P8 is independent of P2-P7. Principles: vectors are the contract;
exact decimals except compat float islands; time is always an input; never build lookup tables from `expected`.

## 5. Profiles and rebuild decisions

<!-- evidence-check: off normative spec; evidence = vectors cited per rule and reference/rebuild-decisions.md -->

- `compat` reproduces the reference at the pin, quirks included (binary-float islands, PostgreSQL vs ClickHouse
  store differences, today's events-processor delivery and loss modes). Choose it for a migration that must produce
  the same invoices before and after.
- `corrected` applies the rebuild decisions (for the events-processor: the ADR-001 delivery contract decided by the
  owner on 2026-10-02; for billing: exact decimals and store parity where ruled). Choose it for a greenfield system.
- A vector is `both` when the reference behaviour is also the corrected one; otherwise a `compat` vector and its
  `corrected` twin (`…NNNx`) share rules and cite the RBD. Corrected vectors whose RBD awaits the owner carry
  `ruling: proposed` and are reported UNRULED (never graded).
- The decision table RBD-1..RBD-106 (behaviour at the pin, evidence, compat expectation, corrected expectation,
  ruling, vectors) is `reference/rebuild-decisions.md`, the defining home of every RBD id. On 2026-10-05: 50 decided
  (10 by the owner: the ADR-001 delivery contract and exact decimals; 4 obvious defect fixes; 36 `KEEP` or grading
  conventions) and 56 proposed (owner question batch OD-21), plus the proposed parts of RBD-1 (an `organization_id`
  that is not UUID text) and RBD-4 (a numeric amount). A `both` vector that cites a proposed RBD next to corrected
  twins of the same op is a profile-neutral control (its input avoids the changed case); the RBD row says so.

The fifteen decisions that change the most results:

| RBD | At the pin (compat) | Corrected | Ruling |
|---|---|---|---|
| RBD-1 | events-processor: a retryable failure younger than 12 h is committed past and lost | retry in place, then retry topic; never commit past a record without a disposition | decided |
| RBD-13 | enriched `value` is binary64 text (`1e+06`, `<nil>`) | exact plain decimal of the JSON literal, `"0"` when missing | decided |
| RBD-15 | subscription matching 1 ms early for about half of all millisecond values | exact millisecond instant | decided |
| RBD-37 | division by zero in an expression: HTTP 500 at the API, process abort (poison record) in the events-processor | 422 / dead letter `evaluate_expression` | proposed |
| RBD-25 | columnar store counts non-numeric values as events worth 0 (relational store drops them) | relational semantics in both stores | proposed |
| RBD-35 | an event exactly at an upgrade instant is billed by both subscriptions | only the new subscription | proposed |
| RBD-48 | the first tier's flat amount is billed at zero usage | KEEP | decided |
| RBD-63 | a termination within 24 h after a period end bills the previous full period; the periodic run skips the ending day | KEEP (both rules together) | decided |
| RBD-64 | month-end anniversary anchors re-clamp every period; 29 February anchors bill 28 February | KEEP | decided |
| RBD-69 | invoice tax = round(Σ unrounded contributions) ≠ Σ rounded fee taxes | KEEP | decided |
| RBD-71 | coupons, credit notes and prepaid credits apply only at finalization | KEEP | decided |
| RBD-84 | webhook body bytes (escapes, key order, float spelling) are signed as sent | KEEP (MUST) | decided |
| RBD-95 | half away from zero everywhere, negatives included | KEEP (MUST) | decided |
| RBD-96 | binary floating-point islands (package count, proration, single-day price, tax and coupon divisions, …) | exact decimals | proposed |
| RBD-103 | split yearly plans terminated after 00:00 UTC of the local day re-bill last month's usage and never bill the current month's | test the termination against the billing instant | proposed |

<!-- evidence-check: on -->

## 6. Vectors

One JSON object per line; envelope fields `kit_schema, id, area, op, title, profile, ruling, pair, rules, rbd,
tags, input, expected, compare?, strict?, timeout_s?, evidence, notes?`. Money in minor units is a JSON integer;
every other decimal is a canonical decimal string; instants carry a zone; local dates come with a time zone;
payload literals whose spelling matters travel as `*_json` strings. `expected` is a subset of the output (or
`{"error": {code, field?}}`); per-path `compare` modes are `exact`, `text`, `numeric` (+ `scale`), `float64`,
`abs_tol`, `range`, `instant`, `set`, `ignore`, `subset`, `strict`. Full rules: `reference/vector-format.md`.

Inventory measured on 2026-10-05 (`python3 scripts/validate-vectors.py --inventory --quiet` prints the current one per
file; counts include the vectors the maintainers keep in the holdout):

<!-- evidence-check: off measured inventory of 2026-10-05; evidence = the validate-vectors.py --inventory run named in the line above -->

| Files | Area(s) | Vectors | both / compat / corrected | both+compat EXECUTED |
|---|---|---|---|---|
| `billing-engine-spec/vectors/domain.{time,money,numbering,catalog}.jsonl` | domain | 153 | 151 / 1 / 1 | 152/152 |
| `…/events.ingest.jsonl`, `…/expression.jsonl` | events, expression | 194 | 175 / 8 / 11 | 183/183 |
| `…/aggregation.{core,store_ch,filters,in_advance,prorated}.jsonl` | aggregation | 288 | 211 / 41 / 36 | 252/252 |
| `…/pricing.{models,in_advance,fees,validation,fixed_charges,misc}.jsonl` | pricing | 357 | 304 / 27 / 26 | 331/331 |
| `…/periods.{boundaries,billing_days,chains,subscription_fee,lifecycle}.jsonl` | periods | 264 | 230 / 17 / 17 | 247/247 |
| `…/invoice.{totals,taxes,coupons,lifecycle,commitment}.jsonl`, `…/credit_notes.jsonl` | invoice, credit_notes | 247 | 215 / 16 / 16 | 231/231 |
| `…/wallets.jsonl`, `…/progressive.jsonl`, `…/alerts.jsonl` | wallets, progressive, alerts | 188 | 177 / 5 / 6 | 182/182 |
| `…/api.jsonl`, `…/webhooks.jsonl`, `…/clock.jsonl` | api, webhooks, clock | 129 | 121 / 4 / 4 | 125/125 |
| billing unit total | 14 areas | 1,820 | 1,584 / 119 / 117 | 1,703/1,703 |
| `billing-engine-spec/scenarios/scn.*.json` | scn | 76 (5 `core`) | every scenario replayed twice on the reference | 76/76 |
| `events-processor-spec/vectors/ep.units.jsonl` | ep | 155 | 77 / 43 / 35 | 117/120 (3 `ep.refresh_member` RECOMPUTED with a note) |
| `reimplementation-kit/selftest/domain.selftest.jsonl` | domain (runner fixtures) | 23 | 23 / 0 / 0 | 23/23 |

<!-- evidence-check: on -->

Every corrected twin is RECOMPUTED by definition (its `ref` names its RBD); all 117 billing twins and 4 of the 35
`ep` twins are `ruling: proposed` and graded UNRULED until the owner rules.

Kit gates (`validate-vectors.py --gate`, `acceptance/thresholds.json` `kit_gates`): billing `both`/`compat` ≥ 95 %
EXECUTED, ≤ 5 % RECOMPUTED, 0 EXTRACTED; scenarios 100 % EXECUTED; `ep` `both`/`compat` ≥ 95 % EXECUTED (the rest
RECOMPUTED with a note, corrected twins not counted). Size budget (`kit_budget`, whole-kit runs): billing unit vectors
1,450,000 bytes (1,400,000 until 1.2.0), scenarios 600,000, events-processor conformance 650,000, events-processor unit vectors 130,000,
schemas and metadata 420,000, total 3,000,000 (`SIZES` line of the validator; measured 2026-10-05 on 1.6.0: 1,411,838 /
387,658 / 509,473 / 103,944 / 375,882, total 2,856,235).

## 7. Running conformance

```bash
K=.claude/skills/reimplementation-kit
python3 $K/scripts/adapter_ref.py --list-ops | head            # the op catalogue (116 ops) with schema status
bash $K/scripts/kit-selftest.sh                                 # tooling self-test (no lago source needed)
python3 $K/scripts/kitrun.py --impl-cmd "python3 $K/scripts/adapter_ref.py" \
    --vectors $K/selftest/domain.selftest.jsonl --only round    # worked example: 14/14 PASS
python3 $K/scripts/kitrun.py --impl-cmd "python3 my_adapter.py" --areas pricing --report pricing.json
python3 $K/scripts/kitrun.py --impl-cmd "python3 my_adapter.py" --profile corrected --quiet
```

<!-- evidence-check: off procedure; the commands are in the code block above, formats and exit codes are defined in reference/adapter-protocol.md and scripts/kitrun.py -->

- Writing an adapter: import `scripts/adapter_ref.py` and call `serve({"pricing.charge_model": fn, …}, impl=…,
  profiles=[…])`, or port its 60-line loop to any language (rules AP-1..AP-11 in `adapter-protocol.md`): one JSON line
  in, one JSON line out, nothing else on stdout, exact decimals, `unsupported_op` for anything not implemented.
- Reading the output: one line per vector (`PASS|FAIL|ERROR|TIMEOUT|SKIP|UNRULED <id>`), diff lines
  `path: expected X (mode) got Y`, an area table (TOTAL, PASS, FAIL, ERROR, TIMEOUT, SKIP, UNRULED, RATE, CORE,
  THRESH, VERDICT), then `SUMMARY kitrun: areas=… pass=… fail=… vectors=… passed=… skipped_ops=… exit=…`.
- Exit codes: 0 thresholds met; 3 below a threshold or a core vector not passing; 2 setup/protocol error; 4 invalid
  vector files; 1 usage.
- Events-processor: `events-processor-spec/scripts/run-suite.sh --impl-cmd "<consumer>" [--mode db|cache]
  [--profile compat|corrected|both] [--loose-errors]` (its own harness: Kafka, Redis and Postgres owned by the runner).
- Scenarios: `scripts/scenario-replay.py` over the `system.*` ops or `--http BASE_URL` (`reference/scenario-tier.md`).

<!-- evidence-check: on -->

## 8. Grading

<!-- evidence-check: off normative grading thresholds; values = acceptance/thresholds.json, protocol in reference/acceptance-and-grading.md -->

| Component | Areas | Shipped | Holdout | Core |
|---|---|---|---|---|
| CRC-1 primitives | domain | 100 % | 98 % | 100 % |
| CRC-2 pricing | pricing | 98 % | 95 % | 100 % |
| CRC-3 expressions + ingestion | expression, events | 98 % | 95 % | 100 % |
| CRC-4 aggregation | aggregation | 95 % | 90 % | 100 % |
| CRC-5 periods | periods | 98 % | 95 % | 100 % |
| CRC-6 invoicing | invoice, credit_notes | 95 % | 90 % | 100 % |
| CRC-7 wallets, progressive billing, alerts | wallets, progressive, alerts | 95 % | 90 % | 100 % |
| CRC-8 API helpers, webhooks, clock | api, webhooks, clock | 100 % | 98 % | 100 % |
| CRC-9 events-processor | run-suite + ep, one run per profile | corrected run: 100 % of decided, startup 4/4; compat run (loose errors, migration builds): ≥ 90 %; ep ≥ 95 % | — | — |
| CRC-10 (stretch) | scenarios | ≥ 60 % | — | — |

<!-- evidence-check: on -->

"Conformant" for a profile = every area of the component meets its threshold with CORE 100 % on the shipped set
and (graded by maintainers) the holdout. Compat is the migration bar; corrected counts only decided vectors.
The events-processor is graded on SEPARATE runs per profile (its compat goldens require the reference's loss
modes, its corrected assertions forbid them); an implementation may expose a profile switch of its own (for
example an environment variable passed with `--impl-env`), the same build serving both runs, and may cap its
retry delays at 2 s under the suite. Details and the clean-room acceptance protocol:
`reference/acceptance-and-grading.md` (§2.1 for the events-processor runs).

## 9. Triage a failing vector

<!-- evidence-check: off triage procedure (defect classes), not claims -->

1. **Protocol** (ERROR `bad_input`/`internal`, garbage line, timeout): check the adapter against
   `adapter-protocol.md`; a schema ambiguity is a kit format defect (K-FMT), otherwise an implementation bug.
2. **Oracle disagrees** with `expected` (maintainers re-run the vector on the reference): kit vector defect (K-VEC).
3. **Rule missing, ambiguous or contradicted**, or the value is only inferable from vectors: kit spec defect
   (K-SPEC) — log it with the question, where you looked and your assumption.
4. **Rule clear, implementation deviates**: implementation bug (IMPL).

<!-- evidence-check: on -->

Read the diff path first; group failures by op and first diff path — one wrong rule usually explains many vectors.

## 10. Clean-room and legal rules

<!-- evidence-check: off normative clean-room rules; full text and rationale in reference/legal-and-provenance.md, citation rule enforced by validate-vectors.py -->

- lago-api and the umbrella repository are AGPL-3.0. The kit carries behaviour (rules, formulas, tables, fresh
  pseudocode) and behavioural data (vectors), never reference source, comments or internal identifiers.
- Implementers use the clean-room pack only (`scripts/maintainer/kit-pack.sh --cleanroom`: no maintainer tooling,
  no holdout, no oracle document), never the reference repositories; they never mine `expected` for lookup tables.
- Reference citations (`$API/<path>:<line> @591ae90`) appear only in "Provenance (maintainers)" sections and in
  `evidence.ref`. The validator enforces this and rejects scratch paths and investigation ids.
- The expression engine's licence is not stated upstream (KQ-7): the kit specifies the language instead.
- Proprietary rebuilds need legal review of the kit and of the process (KQ-8). Full text:
  `reference/legal-and-provenance.md`.

<!-- evidence-check: on -->

## 11. Scripts

| Command | Purpose | Observed (2026-10-05) |
|---|---|---|
| `python3 scripts/kitrun.py --impl-cmd CMD [--areas …] [--profile …] [--report F]` | run unit vectors through an adapter | vs the oracle on the self-test vectors: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=23 passed=23 skipped_ops=0 exit=0` |
| `python3 scripts/validate-vectors.py [FILES] [--gate] [--rule-coverage] [--inventory]` | format, evidence, budget, content and text checks | on the self-test vectors: `SUMMARY validate-vectors: files=1 vectors=23 scenarios=76 errors=0 warnings=0`; whole kit with `--gate --rule-coverage`: `files=146 vectors=1998 scenarios=76 errors=0 warnings=0` |
| `python3 scripts/adapter_ref.py [--list-ops]` | reference adapter loop + `domain.round` example; op list | `--only round`: 14/14 PASS |
| `bash scripts/kit-selftest.sh [--skip-kit-validate] [--skip-ep-build]` | syntax, 18 runner unit tests, validation, selftest adapter 100 % / mutation ≥ 99 %, EP runner build | `unit PASS Ran 18 tests`; `selftest-pass PASS compat 1529/1529 … corrected 1407/1407 (+unruled 113/113)`; `selftest-mutate PASS detected compat 1527/1529 corrected 1405/1407`; `ep-build PASS`; `SUMMARY kit-selftest: steps=7 pass=7 fail=0 skip=0` (`--skip-ep-build`: pass=6 skip=1) |
| `python3 scripts/selftest/test_runner.py` | runner unit tests (compare modes, crash/timeout/garbage/wrong-id adapters, exit codes 0/2/3/4, parallel, report schema) | `Ran 18 tests … OK` |
| `scripts/maintainer/oracle.sh setup\|db\|clickhouse\|run\|adapter\|env\|status\|stop` | MAINTAINER: the reference at the pin as rspec runner and as adapter | from an empty cache 94 s; `run spec/services/charge_models` 140/140 in 21 s |
| `python3 scripts/maintainer/selftest-adapter.py [--mutate]` | MAINTAINER: answers from `expected` to test the runners | 100 % PASS; mutation detected 100 % |
| `python3 scripts/maintainer/vector-provenance.py` | MAINTAINER: every `evidence.ref` resolves at its pin; non-EXECUTED residue | `SUMMARY vector-provenance: vectors=2074 refs_checked=2249 broken=0 residue_recomputed=3 residue_extracted=0` |
| `python3 scripts/maintainer/holdout-split.py --check\|--write [--seed S] [--prune-vec-tags]` | MAINTAINER: seeded, stratified 20 % holdout into `maintainer-data/holdout/` (lead, at integration) | `--check` on 1.6.0 (report only, the holdout stays stable): `vectors=1975 eligible=444 holdout=329 (16.7 %) moves=74 prunes=0 mode=check` |
| `python3 scripts/maintainer/make-kit-json.py --check\|--write` | MAINTAINER: `kit.json` manifest (sha256 per file, maintainer flags), written last | 1.6.0, `--write` then `--check`: `SUMMARY make-kit-json: files=469 maintainer=70 vectors=1673 … changed=0 mode=check` |
| `bash scripts/maintainer/kit-pack.sh --cleanroom (--out F \| --out-dir D)` | MAINTAINER: clean-room pack (strip, manifest, validator, forbidden-content scan) | `SUMMARY kit-pack: mode=cleanroom files=400 … stripped=70 forbidden=0 validate_errors=0` (inside the pack: `files=112 vectors=1673 scenarios=76 errors=0 warnings=0`) |

## 12. Provenance and maintenance

- Pins: lago-api `591ae9005110` (`research-methodology/scripts/pinned-checkout.sh api`), events-processor tree
  `83e012866f29` (`git rev-parse HEAD:events-processor`). Every vector records its pin, runtime and run date.
- Minting: billing vectors are EXECUTED through the oracle adapter (`reference/maintainer-oracle.md`); events-processor
  vectors through the Go reference (`events-processor-spec`); corrected twins are RECOMPUTED from their RBD.
- Volatile facts and their re-verification:
  - runner behaviour: `python3 scripts/selftest/test_runner.py` → `Ran 18 tests … OK` (2026-10-05);
  - oracle availability: `ORACLE_DB=<db> scripts/maintainer/oracle.sh status` → `db: <db> migrations=1121 want=1121`;
  - self-test vectors vs the reference: `python3 scripts/kitrun.py --impl-cmd "scripts/maintainer/oracle.sh adapter"
    --vectors selftest/domain.selftest.jsonl` → 23/23 PASS (2026-10-05);
  - op catalogue size: `python3 scripts/adapter_ref.py --list-ops | wc -l` → 116 (2026-10-05, every schema `final`).
Update triggers: a lago-api pin bump (re-mint all vectors, `maintainer-oracle.md` §6; the release checklist links
here), an events-processor tree change (regenerate goldens with a reviewed diff), an owner ruling on an RBD (flip
`proposed` → `decided`), a new op or compare mode (minor `kit_version`), an envelope change (`kit_schema`).

Open questions and risks (KQ register, the kit's single home for KQ ids; OD-21..OD-24 are the owner questions
prepared from it):

<!-- evidence-check: off open-question register (questions and their defaults, not claims); owner questions are OD-21..OD-24 -->

| KQ | Question / risk | Default until answered | Who |
|---|---|---|---|
| KQ-1 | Retry-topic name, headers and attempt count of ADR-001; the suite neither seeds nor observes a retry topic, so it cannot tell in-place retry from retry-topic publication, and an implementation that skips in-place retries fails `all_done` in EPC-10/14/15 | corrected assertions check outcomes only; in-place retries first | owner (OD-22) |
| KQ-2 | Production CDC column list and auth (decides RBD-21 and cache-mode CDC scenarios) | repository column list = compat golden; corrected twin proposed | owner (OD-1b) |
| KQ-3 | Rulings for the proposed rebuild decisions (56 RBDs and the numeric-amount part of RBD-4) | ship as `ruling: proposed` (advisory, UNRULED) | owner (OD-21) |
| KQ-4 | Age of a retryable record without `ingested_at` under ADR-001 | today's behaviour: an unknown age counts as past the maximum age (dead letter after the in-place budget; `events-processor-spec` delivery-and-failures.md EP-R4) | owner |
| KQ-5 | DLQ error-code names for new permanent causes | kit defaults, proposed: `decode_event` ("Error decoding event", `raw_event`, the all-empty event) for undecodable bytes; `produce_enriched_event` for a rejected enriched produce; the failing step's own code after an exhausted retry (`events-processor-spec` wire-formats.md §4) | owner |
| KQ-6 | Byte-level vs canonical compat of events-processor outputs | canonical JSON with literal number text | owner |
| KQ-7 | Expression engine licence not stated upstream | specify the language; do not embed | owner + legal (OD-23) |
| KQ-8 | Legal status of AGPL-derived behavioural data for proprietary rebuilds; dirty-room separation | authors are the dirty room; implementers see only the pack | owner + legal (OD-23) |
| KQ-9 | Product scope of premium features and custom aggregation (RBD-97, RBD-98) | premium behind an input flag; custom aggregation optional | owner |
| KQ-10 | Which per-organization store flags production uses (decides the store variant a migration reproduces) | PostgreSQL normative, ClickHouse compat variant | owner |
| KQ-11 | Clean-room isolation channel | DECIDED 2026-10-02 (OD-24, option A): pack-only branch, fresh remote sessions, transcript audit | owner |
| KQ-12 | Oracle reproducibility (conda-forge Ruby, gem and crate hosts, shared PostgreSQL; CI version drift) | record runtime per vector; re-mint on any toolchain change | maintainers |
| KQ-13 | Scenario fidelity (lossy setup mapping, wall-clock leaks, order-dependent examples) | CLOSED: every shipped scenario reproduces on the reference twice plus a mutation check; recording wall-clock steps rebased to whole-second instants | scenario tier |
| KQ-14 | Kafka fake fidelity beyond the tested clients; idempotent librdkafka 2.15.1 producers stall after the runner's injected INVALID_RECORD (UNKNOWN_LEADER_EPOCH), documented as conformance-suite gotcha 11; idempotence is not part of the contract (EP-A7) | document supported clients | maintainers |
| KQ-15 | The events-processor runner needs Go ≥ 1.25 and module download | vendor tarball outside the kit | maintainers |
| KQ-16 | Time-dependent behaviour must take explicit instants | TIME-2; schemas require the instant input | kit core |
| KQ-17 | Every vector is tied to the pin; a bump needs a re-mint and triage | update trigger above | maintainers |
| KQ-18 | Holdout leakage (it lives in the repository) | packs never contain it; rotate the seed per acceptance run | lead |
| KQ-19 | Evidence-check convention for spec skills | evidence-check off markers with a reason | docs owner |
| KQ-20 | Reference behaviours unverified when the plan was written may flip RBD rows | CLOSED: RBD-33, 35, 36, 37, 39, 58, 65, 72, 78 executed (RBD-59 replayed); `rebuild-decisions.md` carries the outcomes | area authors |
| KQ-21 | Size of aggregation and scenario data | CLOSED: caps raised in `thresholds.json` `kit_budget` (section 6) | lead |
| KQ-22 | Op schemas started as skeletons (schema findings were warnings until `final`) | CLOSED: all 116 op schemas `final`, the `ep.*` ones included | area authors |
| KQ-23 | `ep` unit vectors against their cap | cap 130,000 bytes (vectors plus holdout `ep.*`); 103,944 measured (2026-10-05) | lead |
| KQ-24 | Unpaired compat/corrected vectors (no corrected contract for an input) | accepted with a note (`vector-format.md` §6) | lead |
| KQ-25 | MRO is accepted with exponent 1 but 5 minor units per major unit, and the two reference money paths disagree on it | `domain.to_minor_units` defined only for power-of-ten currencies; rebuilds reject or special-case MRO | owner (drop MRO, add MRU?) |
| KQ-26 | HUF and MGA have no minor unit in the reference (ISO 4217 lists 2) | same in both profiles | owner |
| KQ-27 | Evidence class of identity-computed fields (`precise_amount_cents` of `domain.to_minor_units`, `domain.to_local`): computed inside the oracle, not by a reference method | EXECUTED with a Provenance disclosure | lead |
| KQ-28 | Per-billing-entity sequence ignores drafts that already hold a number, so a draft and a newly finalized invoice can get the same number (`domain.numbering.next_sequential_id.011`) | profile `both` (reference behaviour) | owner (new RBD?) |
| KQ-29 | The billing API and the events-processor embed different patch releases of the expression engine's decimal library; number text forms can differ between surfaces (zero with a scale today) | each surface's observed text pinned | maintainers (keep builds in lockstep on a bump) |
| KQ-30 | Processor-surface expression vectors run through the engine build, not the processor binary | CLOSED: mixed-surface convention (`vector-format.md` §5); the processor's own number re-encoding is graded by `ep.*` | kit core |
| KQ-31 | Internal errors at ingestion: `NaN`, ±Infinity and out-of-range timestamps, and pre-1970 events whose metric has an expression, answer HTTP 500 | ungraded (prose only) | owner (new RBD? proposal: `invalid_format` 422 for NaN, ±Infinity and times outside the relational store's range −210866803200 s .. 9224318015999.999999 s; pre-1970 events with an expression evaluated like any other event, BE-EX-32) |
| KQ-32 | A single event without an external subscription id has no ingestion idempotency (batches reject such repeats, RBD-33) | profile `both` | owner |
| KQ-33 | Precision of aggregation divisions (relational ≈ 20 significant digits; columnar 10 fractional digits for prorated unique counts and binary64 for prorated sums, BE-AG-74; ceil-5 islands) | weighted-sum shares (level × seconds)/(D × 86 400), product first; the reference keeps ≥ 16 significant digits and ≥ the product's decimals (≥ 6), compared at 12 places (6 for a 10¹⁵ level, `aggregation.core.weighted.017`); prorated islands q (20 places), p17 and p16 per BE-AG-56 under RBD-96 | owner |
| KQ-34 | Columnar duplicates without the de-duplication flag depend on insert batching and merges | prose only; the corrected RBD-32 makes it moot | maintainers |
| KQ-35 | The binary64 → decimal coercion (shortest text cut to 16 significant digits) is a property of the reference runtime and decimal library | any runtime or library bump re-mints every float-island vector (adds to KQ-12) | maintainers |
| KQ-36 | Manual termination of an active subscription always emits `subscription.updated` before `subscription.terminated` | profile `both` | owner (new RBD? proposal: only when options change) |
| KQ-37 | Time-zone change continuity: previous end `.999999` + 1 s leaves a sub-second gap of uncovered usage (RBD-67) | KEEP | owner (proposal: + 1 µs) |
| KQ-38 | Split yearly/semiannual plans have no fixed-charges bounds outside the first month, current usage included, so usage views omit fixed charges | as at the pin | owner (intended?) |
| KQ-39 | Fractional `trial_period` values carry a day fraction that date arithmetic truncates | prose only | owner (restrict trials to whole days?) |
| KQ-40 | Credit notes on version-2 invoices: coupon adjustment 0 while the tax base still deducts the coupon share | KEEP for migrated legacy invoices | owner |
| KQ-41 | Oracle calls freeze the clock, so records created in one call share `created_at` | CLOSED: documented in `maintainer-oracle.md` §4; vectors order by sequential id | maintainers |
| KQ-42 | A metric alert without a matching fee is skipped without updating its previous value (stale baseline); a recurring usage threshold passes at most once per check | KEEP | owner |
| KQ-43 | The invoices count-cache key ignores the customer of a customer-scoped list and array filters, so two lists can share a cached total for 30 minutes | profile `both` | owner (new RBD? proposal: key on path and all filters) |
| KQ-44 | Termination alerts compare UTC dates while termination uses the customer-local day; draft finalization compares the clock's UTC date with local dates (code-read) | as at the pin | owner |
| KQ-45 | Kit error codes for unhandled reference failures and unknown webhook types | CLOSED: `server_error`, `unknown_event_type` (`vector-format.md` §4.4) | kit core |
| KQ-46 | `system.snapshot` exposes no alerts, lifetime-usage objects or webhooks, so those scenarios grade invoices only | extend in a minor kit version | maintainers |
| KQ-47 | Columnar-store scenarios need accepted events usable before `system.api` returns (a real asynchronous events-processor must be drained in test builds) | normative in `scenario-tier.md` | owner (confirm) |
| KQ-48 | Same-instant order beyond aggregation (drafts finalized in one clock run and their per-billing-entity numbers; same-instant wallet transactions) is undefined at the pin | excluded from the scenario tier | owner (extend the RBD-30 tie-break?) |
| KQ-49 | The events-processor accepts hexadecimal-float and other non-decimal spellings of `timestamp` | compat only, not part of the contract | owner (reject in corrected?) |
| KQ-50 | The `ep` gate counted corrected twins, which are RECOMPUTED by definition | CLOSED: the gate counts `both`/`compat` only | kit core |
| KQ-51 | API requests the reference answers with an internal error (HTTP 500) instead of a validation error: `event_types` given as a JSON number or boolean (`webhooks.normalize_event_types.013`), a plan fixed charge without `add_on_id`, a billing entity without `code`, a fees-index `per_page` given as a list (billing-engine-spec chapters 11, 12) | compat `server_error`; request bodies prose only | owner (new RBD? proposal: 422 validation error) |
| KQ-52 | Corrected precision of per-event prorated values: `aggregation.prorated.sum.009` (`both`) lists v × q(n, D) with a 20-place quotient, which an exact-decimal profile cannot list exactly (72/31) | as at the pin (the 20-place quotient in both profiles) | owner / maintainers |
| KQ-53 | DB mode accepts any UUID spelling the database accepts as `organization_id` and emits the raw text, while cache mode needs the canonical text; non-UUID text is lost silently in DB mode (EP-E4, EPC-03) | compat as observed; corrected: PERMANENT for non-UUID text (RBD-1, proposed); no corrected contract for non-canonical spellings | owner |
| KQ-54 | Raw-record field names match ignoring case in the reference (EP-C1, `ep.decode.023`) | kept in both profiles (ASCII case graded, Unicode folding not) | owner (exact names in corrected?) |
| KQ-55 | Premium percentage validation fails with an unhandled error when both per-transaction bounds are present and one is a string that is not a decimal, a blank string included (a blank bound alone is skipped; BE-PR-75) | prose only, not graded | owner (new RBD? proposal: a blank bound counts as absent, a non-decimal bound gets `invalid_amount`, min ≤ max is compared only when both are valid) |
| KQ-56 | Unique-count current usage in advance reports `count` differently with and without grouping: ungrouped = the adjusted, clamped aggregation; per group = the group's raw unique count (BE-AG-44, `aggregation.in_advance.current.007`) | profile `both` | owner (new RBD?) |

<!-- evidence-check: on -->

Author questions answered by a rebuild decision are closed there and have no row: the cache-mode key-prefix leak
(RBD-99), the in-advance quirks (RBD-100, RBD-101), fixed-charge UTC dates (RBD-102), split-plan termination
(RBD-103), the wallet tie order (RBD-104, RBD-105 for the interval anchor), the credit-note offset (RBD-106), the
grouped prorated phantom day (RBD-31), division by zero (RBD-37) and the simulator's scope and event count (RBD-54).

## 13. Changes

### 1.6.0 (2026-10-05)

Sixth fix round, after the transcript audit of the fifth fix-loop run: the column rule did not say whether its 16-digit
step rounds the exact binary64 value or its shortest text, and the shipped vectors passed under either reading
(they differ on about 8 % of amounts in [2^36, 10^11) and 4 % to 5 % above). Probes on the reference settled it: the
exact value. 3 vectors added (1 `both`, 1 `compat`, 1 corrected twin), none changed or removed; both clean-room
implementations of the invoice area already follow the reference and pass them.

<!-- evidence-check: off change summary; evidence = the rule and vector ids named per line and the gate runs of section 11 -->

| Area | Changes |
|---|---|
| invoice, credit notes | chapter 07 notation paragraph: the 16 digits are those of the exact binary64 value of `round5`'s result, not of its text; "`round5` alone" now holds below 2^36 (about 6.87 × 10^10), not below 10^11 (78096345254.9564 → 78096345254.95641, `invoice.void.014`, profile-neutral; 820741212006.6481 → 820741212006.6479, `invoice.void.015` and twin `.015x`); BE-IV-42 and BE-CN-7 say the same |
| kit | version 1.6.0; RBD-68 row cites the new vectors; billing unit vectors 1,817 → 1,820 |

<!-- evidence-check: on -->

### 1.5.0 (2026-10-05)

Fifth fix round: a cross-check of the implementations' column rule against the maintainer model on random inputs found
two more points the text left open, both settled on the reference: an exact tie at the 16th significant digit goes to
the even digit, and an odd `f` in `round5` from 2^52 up is kept. 5 vectors added (1 `both`, 2 `compat`, 2 corrected
twins), none changed or removed; implementations of the invoice and credit-note areas must be re-run.

<!-- evidence-check: off change summary; evidence = the rule and vector ids named per line and the gate runs of section 11 -->

| Area | Changes |
|---|---|
| invoice, credit notes | the column rule's 16-digit step rounds an exact tie to even (256924291381.03125 → 256924291381.0312, `invoice.void.013` and twin `.013x`); `round5` keeps an odd `f` from 2^52 up (72606570804.87341, `invoice.void.012`, profile-neutral); a further note-tax case of the column rule (171802469353.58026 → 171802469353.5803, `credit_notes.compute.021` and twin `.021x`) |
| kit | version 1.5.0; RBD-68 row cites the new vectors; billing unit vectors 1,812 → 1,817 |

<!-- evidence-check: on -->

### 1.4.0 (2026-10-05)

Fourth fix round, after the third fix-loop run on 1.3.0: the two implementations of the column rule agreed on every
vector but not on amounts from about 4.5 × 10^10 up. The pinned Ruby and the reference show that `round5`'s correction
adds 0.5 in binary64, which the 1.3.0 text wrote as an exact sum. 2 vectors added (1 `compat`, 1 corrected twin), none
changed or removed; implementations of the invoice and credit-note areas must be re-run.

<!-- evidence-check: off change summary; evidence = the rule and vector ids named per line and the gate runs of section 11 -->

| Area | Changes |
|---|---|
| invoice, credit notes | BE-IV-14 `round5`: `f = round(x ⊗ 100000)` half away on the binary64 product, correction `(f ⊕ 0.5) ⊘ 100000 ≤ x` with a binary64 sum; from `f ≥ 2^52` an even `f` is raised by one (47033384975.09552 → 47033384975.09553, `invoice.void.011` and twin `.011x`); every use of `round5` (tax rate, coupon shares, the column rule) follows it; the maintainer model `recompute-invoicing.py` rounds the exact product half away (its `floor(x + 0.5)` was wrong from 2^52 up) |
| kit | version 1.4.0; RBD-68 row cites the new vectors; billing unit vectors 1,810 → 1,812 |

<!-- evidence-check: on -->

### 1.3.0 (2026-10-05)

Third fix round, after the second fix-loop run on 1.2.0: two implementers read BE-CN-7's wording ("stored by rounding
its text to 5 places") against `credit_notes.compute.009` and stored the note's precise taxes in two different ways.
Probes on the reference show one storage rule for every binary64 written to a 5-place column: `round5`, then 16
significant digits, then 5 places, which differs from `round5` alone from 10^11 up. 4 vectors added (2 `compat`,
2 corrected twins), none changed or removed; implementations of the invoice and credit-note areas must be re-run.

<!-- evidence-check: off change summary; evidence = the rule and vector ids named per line and the gate runs of section 11 -->

| Area | Changes |
|---|---|
| invoice, credit notes | the column rule in the chapter 07 notation paragraph (`round5`, then 16 significant digits, then 5 places; 102880657510.79861 → 102880657510.7986, `invoice.void.010` and twin `.010x`); BE-IV-42 void items and BE-CN-7 note precise taxes follow it (216049380771.60492 → 216049380771.6049, `credit_notes.compute.020` and twin `.020x`); the maintainer model `recompute-invoicing.py` applies it |
| kit | version 1.3.0; RBD-68 row cites the new vectors; billing unit vectors 1,806 → 1,810 and their size cap 1,400,000 → 1,450,000 bytes (`acceptance/thresholds.json` `kit_budget`, `reference/vector-format.md` section 9) |

<!-- evidence-check: on -->

### 1.2.0 (2026-10-05)

Second fix round, after seven implementers re-ran on the 1.1.0 pack and met every threshold: every question they
still logged, and the two minor spec items 1.1.0 left open, was classified and the kit side closed, each new
reference claim executed on the reference first. 17 vectors added (11 `both`, 3 `compat`, 3 corrected twins), none
changed or removed; an implementation graded on 1.1.0 must be re-run on the areas below.

<!-- evidence-check: off change summary; evidence = the rule and vector ids named per line and the gate runs of section 11 -->

| Area | Changes |
|---|---|
| grading, format | NUM-OUT is expected on the range bounds that BE-PR-58 echoes as JSON numbers (`reference/vector-format.md` §4.1, `reference/acceptance-and-grading.md` §3) |
| expression | the BE-EX-40 member checks also apply to an `event` object on the processor surface (`expression.ep.022`) |
| aggregation | BE-AG-74 states the columnar store's own decimal→binary64 conversion (3.1 → 3.0999999999999996, 8.3 → 8.3) and its undefined summation order (a part with three or more contributions is not reproducible); `aggregation.store_ch.prorated.005`, `.006` and their corrected twins |
| pricing | BE-PR-41 covers grouped charges (`pricing.projection.010`) and marks `days(from, to) ≤ 0` not reachable; BE-PR-58 says the NUM-OUT warning on echoed bounds is expected; BE-PR-71 uses the already-billed units as given; BE-PR-87 covers the pricing-unit op record (`pricing.pricing_unit.008`) in both profiles; new BE-PR-88 (period ratio of the current-usage fee path, prose only, not observable) |
| invoice, credit notes | BE-CN-18 exit order: upgrade with refund or offset answers `server_error` before the creditable-amount exits (`credit_notes.termination.013`..`.015`); `dec16` is a cut of the shortest text after 16 significant digits, never a rounding (`credit_notes.compute.019`, `019x`); BE-IV-17 checks `expiration_at` whatever `expiration` says (`invoice.coupon_create.017`); BE-IV-18 value checks apply whatever the coupon type (`invoice.coupon_create.016`, `invoice.coupon_apply.016`, `.017`); a void item just below a tie at 5 places (`invoice.void.009`); schema descriptions of `invoice.coupon_apply` (`applied_before`), `invoice.coupon_create`, `credit_notes.termination` and `expression.evaluate` (`event`) |
| clock | BE-CK-2: ticks at whole-second instants, the period counted from the previous run cut to the second, the op window half-open `[from, to)`; a `from` with a fraction of a second is not graded |
| kit | version 1.2.0; RBD-68 and RBD-96 rows (vectors, BE-AG-74 wording); billing unit vectors 1,789 → 1,806 (section 6); the maintainer model `recompute-invoicing.py` rounds void items with round5 and applies the dec16 cut |

<!-- evidence-check: on -->

### 1.1.0 (2026-10-05)

Fix round after the clean-room acceptance run of 1.0.0: every gap that twelve independent implementations logged
was classified (vector, format, spec or implementation defect) and the kit defects were fixed, each new reference
claim executed on the reference first. Vectors added in 1.1.0 pin behaviour that 1.0.0 left open or stated wrongly,
so an implementation graded on 1.0.0 must be re-run (138 vectors added, none removed). Changed 1.0.0 vectors: six
`both` vectors became `compat` with a new corrected twin (`pricing.pricing_unit.006`, `pricing.volume.008`,
`aggregation.prorated.sum.011`, `aggregation.filters.mi.015` and two holdout members); `pricing.gp.007` asserts one
more field; `pricing.percentage.008` and a holdout member gained consistent running totals (outputs unchanged);
`aggregation.filters.select.008x` expects the profile-independent selection; three columnar twins compare at 12 places.

<!-- evidence-check: off change summary; evidence = the rule and vector ids named per line, the RBD rows of reference/rebuild-decisions.md and the gate runs of section 11 -->

| Area | Changes |
|---|---|
| grading | events-processor graded on separate runs per profile, an implementation's own profile switch allowed; retry delays may be capped at 2 s under the suite; the suite's settle and stop windows stated; a corrected scenario whose IUT never becomes ready fails every assertion (`reference/acceptance-and-grading.md` §2.1, `acceptance/thresholds.json`) |
| domain | BE-DM-15 offset sign corrected (the vectors were right), `domain.time.days_between.013`; `domain.to_minor_units` defined for power-of-ten currencies only; instants carry at most 6 fractional digits; finalizing without sequential ids (`domain.numbering.invoice_number.013`..`.015`); the fee-tax row `(base × rate) ⊘ 100` stated identically in BE-DM-27/30 and BE-IV-11/12 |
| events, expression | batch duplicate flagging per `transaction_id` (BE-EV-43/44); relational timestamp range and pre-1970 events with an expression (KQ-31); whitespace is never trimmed; zero text forms and zero-operand subtraction (BE-EX-15/21 corrected); underscores in numeric strings; required members of the processor-surface event; exact number literals |
| aggregation | `metric.code` in the aggregate schema; per-event prorated values; grouped prorated unique count adds a day per closed pair (RBD-31); equal-time active-before (RBD-30); grouped `count` in advance (KQ-56); weighted-sum precision and evaluation order; the number forms q, p17 and p16 of BE-AG-56; new twins `aggregation.prorated.sum.011x`, `aggregation.filters.mi.015x`; `select.008x` and three columnar twins made derivable; columnar prorated sums evaluated in binary64 (BE-AG-74, new) |
| pricing | detail JSON types (BE-PR-58); 15-place storage of every fee (BE-PR-87, new); projection ratio denominator and binary64 text (BE-PR-39..41); validation check order and record de-duplication (BE-PR-78); the corrected percentage walk (RBD-41) and graduated-percentage tiers (RBD-42); the evaluation order of every island (BE-PR-85); new twins for `pricing.pricing_unit.006`, `pricing.volume.008` and their holdout members |
| periods | the 26 h window is strict (BE-SP-23); "created before" compares creation instants (BE-SP-39); `utc_hour` evaluates the predicate only; chain element keys; fee-gate output; neighbour statuses on termination; no trial without a trial period; the backdating clamp scope (BE-SP-49/50); an upgrade credits one day MORE (BE-SP-58, chapter 08 BE-CN-16 aligned); offsets of opposite sign (`periods.termination_credit_days.010`); `days × (amount ÷ length)` (BE-SP-38) |
| invoice, credit notes | tax division order (`invoice.apply_taxes.011`); coupon rounding by coupon kind (unlimited binary64, limited exact, BE-IV-23/25); credit-note share and refundable amount; coupon creation and application check order (BE-IV-17/18); credit-note validation order (BE-CN-12); termination note truncation, upgrade with refund or offset answered `server_error`, voided-invoice input and its precedence (BE-CN-17/18); void items at 5 places (`invoice.void.008x`); commitment proration diverges under RBD-52 (`invoice.commitment.010x`); the note's tax rate is decimal (BE-CN-8); a binary64 stored at 5 places is rounded by round5 (chapter 07 notation, BE-IV-42) |
| wallets, progressive, alerts | credit division decimal for currencies with minor units and binary64 for zero-exponent ones (BE-WL-2/4); interval top-up target; ongoing-balance flag scope; `parent_plan` precedence (BE-PB-5) |
| api, webhooks, clock | the 75 configured webhook names with object types (BE-WH-11); `payload_envelope` outputs; one-second clock ticks (BE-CK-2, RBD-94); environment value reading (BE-CK-12, new); scalar filters in the count-cache key (BE-API-27); RBD-79 corrected wording |
| events-processor | default dead-letter names, proposed (KQ-5); unknown record age (KQ-4); field names matched ignoring case (KQ-54); negative and very large timestamps; non-UUID organization ids (EP-E4, EPC-03 extended, RBD-1 partly proposed); idempotent-producer and retry-delay gotchas; pause semantics |
| kit | version 1.1.0; RBD rows updated (RBD-1, 4, 6, 27, 30, 31, 33, 35..38, 41, 42, 46, 52, 55, 57, 58, 68, 75, 79, 91, 94, 96, 101, 103, 104); KQ-52..KQ-56; op catalogue and precise-money rows of `reference/vector-format.md`; billing unit vectors 1,655 → 1,789 and `ep` unit vectors 151 → 155 (section 6) |

<!-- evidence-check: on -->
