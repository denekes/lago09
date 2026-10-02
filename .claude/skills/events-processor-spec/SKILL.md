---
name: events-processor-spec
description: "Language-neutral behaviour spec of the Lago events-processor for a clean-room rebuild: env, topic, group, key, Redis and Postgres contract; raw, enriched, in-advance and dead-letter wire formats; decoding, timestamps, metric and subscription resolution, value string, expressions, pay-in-advance split, refresh flag; DB and memory-cache (CDC) modes; delivery per profile (compat today, corrected per ADR-001); black-box conformance suite (35 scenarios, goldens, run-suite.sh --impl-cmd). Use to implement, port or grade an events-processor. Not for changing the Go code (use architecture-contract)."
---

# events-processor-spec

Behaviour specification and conformance suite for re-implementing the Lago events-processor (the Kafka
consumer that turns raw usage events into enriched, charged-in-advance and dead-letter records plus a Redis
refresh flag), in any language, without its source. Facts as of events-processor tree `83e012866f29` (the
reference, "compat" profile) and the kit's corrected profile; kit v1.0.0. **Production runs memory-cache mode
(owner decision OD-1); DB mode is the development and fallback mode; the suite grades both.**

> **Licence.** The Lago events-processor and lago-api are AGPL-3.0. This skill describes behaviour in neutral words,
> tables, fresh pseudocode and behavioural data (scenarios, goldens, vectors). Its suite runner is kit code. A
> rebuild that will not be AGPL needs legal review of the kit and of the process
> (`reimplementation-kit` reference/legal-and-provenance.md).

## 1. When to use / when not

Use it to: implement or port an events-processor; decide which delivery profile a deployment needs; run the
black-box suite against an implementation (`scripts/run-suite.sh --impl-cmd`); run the `ep.*` unit vectors with
`reimplementation-kit` kitrun; triage a DIFF or FAIL; answer "what does the processor emit for this input?".

Not for: changing or debugging the Go code itself (`architecture-contract`, `debugging-playbook`); fixing the
reference's event accounting (`event-accounting-campaign`); the billing engine (`billing-engine-spec`); the kit's
formats, runners and grading in general (`reimplementation-kit`); glossary (`domain-reference`).

## 2. Terms

<!-- evidence-check: off definitions of the terms, not claims -->

| Term | Meaning |
|---|---|
| raw / enriched / in-advance / dead-letter record | input record; output for every enriched event; copy for pay-in-advance charges; failure record |
| refresh flag | member of the Redis sorted set `subscription_refreshed_v2` asking the billing engine to refresh a subscription's usage |
| compat profile | reproduces the reference exactly, quirks and silent-loss modes included (migration testing) |
| corrected profile | ADR-001 delivery contract plus the decided rebuild decisions (RBD-n, `reimplementation-kit` reference/rebuild-decisions.md); `proposed` items are advisory (UNRULED) |
| DB mode / memory-cache mode | catalog read from Postgres per event / held in memory from a snapshot plus CDC topics |
| disposition | the durable outcome of a record: enriched (+ in-advance), retry-topic, or dead-letter |
| ledger class | per raw record in a run: ENRICHED, DLQ, ENRICHED+DLQ, NO_OUTPUT_COMMITTED (silent loss), PENDING_UNCOMMITTED |
| IUT | implementation under test, any program started by `--impl-cmd` |
| quiescence | nothing observable changed for 1 s (all committed) or 3 s (some uncommitted) |
| EP-xn | rule ids of this skill (EP-A contract, B batches/commits, C decode, D time, E metric, F value, G expressions, H subscription, I outputs, J/K in-advance and flag, L reference failures, M shutdown, N cache mode, P suite, R corrected delivery, W wire) |
| EPC-NN | conformance scenarios |

<!-- evidence-check: on -->

## 3. System context

```
 raw topic ──▶ [ events-processor ] ──▶ enriched topic ──▶ ClickHouse event store
                 │   ▲                 ─▶ charged-in-advance topic ──▶ billing engine (instant fees)
                 │   │                 ─▶ dead-letter topic ──▶ operators / dead-letter view
                 │   └── catalog: Postgres per event (DB mode)
                 │       or snapshot + six CDC topics (memory-cache mode, production)
                 └──▶ Redis sorted set subscription_refreshed_v2 ──▶ billing engine refresh clock
```

## 4. Implementation contract (summary of `reference/contract.md`)

<!-- evidence-check: off normative spec (summary of reference/contract.md); evidence = the EP-A/EP-M rule ids cited inline and the startup scenarios EPC-21, EPC-26..29 -->

- Configuration by environment: `LAGO_KAFKA_BOOTSTRAP_SERVERS`, `LAGO_KAFKA_RAW_EVENTS_TOPIC`,
  `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC`, `LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC`,
  `LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC`, `LAGO_KAFKA_CONSUMER_GROUP` (prefix), SASL/TLS variables, `DATABASE_URL`,
  `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` (default 200), `LAGO_REDIS_STORE_URL`/`_DB`/`_PASSWORD`/`_TLS`,
  `LAGO_USE_MEMORY_CACHE` (exactly `true`), `LAGO_DEBEZIUM_TOPIC_PREFIX`. Names are part of the compat contract; a
  rebuild may wrap them.
- Consumer group `<prefix>_<raw topic>`, earliest offset for a new group, manual commits (EP-A6). Outputs keyed
  `<organization_id>-<transaction_id>`, dead letters unkeyed (EP-A7). Cache mode: six CDC consumers in fresh
  groups per start (EP-A8).
- Startup (EP-A1, EP-A2): cache snapshot and CDC consumers, broker list, three producers, Postgres (DB mode),
  Redis, then the group join; any broken dependency or empty required variable exits NON-ZERO before joining
  (corrected: within 30 s, never crash or hang, RBD-23). Readiness = group Stable owning every raw partition (EP-A4).
- SIGTERM: finish the in-flight batch, commit, leave, exit 0; restart loses and duplicates nothing (EP-M1).

<!-- evidence-check: on -->

## 5. Per-record pipeline (summary of `reference/processing-rules.md`)

<!-- evidence-check: off normative spec (summary of reference/processing-rules.md); evidence = the EP rule ids cited per step, each with its EPC scenarios and ep.* vectors -->

1. **Decode** (EP-C1..C5): one JSON object with typed fields; undecodable → nothing produced (reference: committed;
   corrected: dead letter with raw bytes, RBD-4). Unknown fields dropped; last duplicate key wins; property
   numbers re-encoded through binary64 in the reference (corrected proposal RBD-14: literal text kept).
2. **Time** (EP-D1..D6): number, decimal string or RFC 3339 accepted; emitted timestamp = ms-truncated seconds
   (JSON numbers untruncated in the reference); matching instant computed in binary float in the reference (1 ms
   early for about half of all ms values; corrected RBD-15 exact); RFC 3339 offsets compared as wall clock in DB
   mode (corrected RBD-16 UTC); `NaN`/`Inf` silently lost in the reference.
3. **Metric** (EP-E1..E3): exact (organization, code), not deleted; not found → dead letter
   `fetch_billable_metric`; filters never applied.
4. **Expression** (EP-G1..G3): if the metric has one and `source ≠ http_ruby`; result stored as a STRING in
   `properties[field_name]`; failure → dead letter `evaluate_expression`.
5. **Value** (EP-F1..F5): count → `"1"`; else the text of `properties[field_name]` (reference: binary64 `%g`-like
   text, `1e+06`, `<nil>`; corrected RBD-13: exact plain decimal, `"0"` for missing). Table: `reference/value-corpus.md`.
6. **Subscription** (EP-H1..H8): exact external id, window `started_at ≤ t ≤ terminated_at`, open first then
   latest `terminated_at` then latest `started_at`; recurring metrics fall back to "now"; none = empty ids, no side
   effects; status not read; precision and window per mode.
7. **Outputs** (EP-I1..I5, EP-J1..J3, EP-K1..K2): enriched always; in-advance iff subscription, not
   API-post-processed and a non-deleted pay-in-advance charge; refresh member `<org>:<sub>|<10 s bucket>` with
   score = now. Wire formats: `reference/wire-formats.md`.

<!-- evidence-check: on -->

## 6. Delivery semantics (summary of `reference/delivery-and-failures.md`)

Reference (compat): batch per partition, concurrent records; retryable failures younger than 12 h stay
unprocessed and a later batch commits past them (silent loss); older or without `ingested_at` → dead letter;
broker rejections give empty-code dead letters or nothing at all; Redis and charge-lookup failures drop side
effects; database connection exhaustion loses a large part of a burst (measured 85-170 of 201 in nine runs).

Corrected (ADR-001, decided): classify SYSTEMIC / TRANSIENT / PERMANENT; commit only past records with a durable
disposition (acks=all); SYSTEMIC → pause the partition with backoff; TRANSIENT → bounded in-place retry of the
failed step, then retry topic (KQ-1), dead letter after N attempts or 12 h; PERMANENT → dead letter at once
(undecodable with raw bytes); enriched first, then in-advance and flag; downstream idempotency on
`transaction_id` required.

<!-- evidence-check: off normative spec; evidence = vectors and EPC ids cited per rule and reimplementation-kit reference/rebuild-decisions.md -->

| RBD | Topic | Corrected | Ruling |
|---|---|---|---|
| RBD-1..3 | transient failures, re-delivery, horizon | retry in place / retry topic, never commit past | decided (KQ-4 open for unknown age) |
| RBD-4 | undecodable, non-finite timestamp | dead letter with cause | decided (names KQ-5) |
| RBD-5, 10 | dead-letter produce rejected, connection exhaustion | SYSTEMIC pause | decided |
| RBD-6, 8, 9 | produce/charge/flag side effects | enriched first, retry only the failed side effect | decided |
| RBD-7 | in-advance produce rejected | never dead-letter an enriched event | proposed |
| RBD-11, 12 | duplicates, graceful restart | KEEP | KEEP |
| RBD-13, 15, 16, 17 | value text, matching instant, offsets, bound precision | exact decimal / exact ms / UTC / ms both modes | decided |
| RBD-14, 18 | literal numbers, emitted timestamp of numbers | preserve / ms-truncate | proposed |
| RBD-19, 20, 21 | status, cache window, CDC column gap | owner questions | proposed |
| RBD-22 | `""` label for retired types, expression result as string | KEEP | KEEP |
| RBD-23, 24 | startup failure, error texts and key order | exit non-zero ≤ 30 s / not a contract | decided |
| RBD-99 | cache-mode external-id key-prefix match (EP-H8) | exact external-id equality in both modes | proposed |

<!-- evidence-check: on -->

## 7. Modes (summary of `reference/memory-cache-mode.md`)

<!-- evidence-check: off normative spec (summary of reference/memory-cache-mode.md); evidence = EPC-04, EPC-06, EPC-31..34 and the ep.match_subscription vectors -->

| Aspect | DB mode | Memory-cache mode (production) |
|---|---|---|
| not-found text | `record not found` | `Key not found` |
| bounds | ms-truncated | µs |
| RFC 3339 offset | wall clock | instant |
| terminated subscriptions | all | ≤ 1 month before the snapshot (+ CDC) |
| external id `acme` vs `acme:eu` | exact | prefix leak |
| freshness | per event | snapshot + CDC lag; a CDC row replaces the entry WHOLE (a missing column resets it) |
| restart | — | six new CDC groups, full CDC replay |

<!-- evidence-check: on -->

## 8. Conformance suite (summary of `reference/conformance-suite.md`)

```bash
bash .claude/skills/events-processor-spec/scripts/run-suite.sh --impl-cmd "<your binary>" \
     [--mode db|cache] [--profile compat|corrected|both] [--loose-errors] [--only REGEX] [--keep DIR] [--pg-admin URL]
```
The runner owns Kafka (in-process, TCP), Redis (in-process, TCP) and a scratch Postgres database per scenario;
the IUT gets the env contract above and a SELECT-only role. Needs Go ≥ 1.25 (runner build, cached in
`$LAGO_SKILLS_CACHE/epconf-bin/`), `psql`, Postgres ≥ 15. Compat = canonical golden text per mode (multiset of
lines; `--loose-errors` masks error texts and the exact startup exit status); corrected = assertion files with
`rbd` and `ruling` (proposed failures are UNRULED, never fatal). Exit 0 / 3 (DIFF or FAIL) / 2 (setup).

<!-- evidence-check: off scenario catalogue (what each EPC pins); cards in reference/scenario-catalogue.md, results reproducible with run-suite.sh (section 11) -->

| EPC | Pins | EPC | Pins |
|---|---|---|---|
| 00 | smoke mix of 9 records | 18 | broker rejects enriched produce |
| 01 | aggregation types, labels, value | 19 | broker rejects dead-letter produce |
| 02 | filters pass through | 20 | broker rejects in-advance produce |
| 03 | metric resolution | 21 | graceful restart, 200 records |
| 04 | subscription matching (18 cases) | 22 | three partitions |
| 05 | expressions | 23 | organization scoping |
| 06 | pay-in-advance split | 24 | refresh-flag members |
| 07 | value corpus (27 literals) | 25 | duplicate raw record |
| 08 | timestamp shapes incl. NaN/Inf | 26-29 | startup contract |
| 09 | undecodable records | 30 | database connection burst (assertions only) |
| 10, 15 | transient DB fault then later batch (loss) | 31 | CDC charge row without `pay_in_advance` |
| 11 | same fault, restart | 32 | CDC new metric |
| 12, 13, 14 | retry horizon 13 h / none / 11 h | 33 | CDC metric delete |
| 16, 17 | charge-lookup / Redis fault | 34 | CDC subscription termination |

<!-- evidence-check: on -->

Reference results (2026-10-02, three full passes per mode): DB 30/30 and cache 27/27 compat MATCH; corrected
decided FAIL DB EPC-04, 07, 08, 09, 10, 14, 15, 16, 17, 18, 19, 30 and cache EPC-04, 07, 08, 09, 17, 18, 19;
UNRULED EPC-20 (+ EPC-31 in cache). A Python self-test IUT built from these rules passes every decided
assertion except EPC-18 (a documented deviation the suite catches). Cards: `reference/scenario-catalogue.md`.

Grading (component CRC-9 of `reimplementation-kit`): corrected decided assertions 100 % in both modes; startup
EPC-26..29 4/4; `ep` unit vectors ≥ 95 % (core 100 %); compat with `--loose-errors` ≥ 90 % of DB goldens only
for a migration-compat build.

## 9. Unit vectors (`vectors/ep.units.jsonl`)

151 vectors over six ops, for fast feedback before Kafka: `ep.decode` (19 + 2 corrected twins),
`ep.parse_timestamp` (18 + 7), `ep.value_string` (38 + 17), `ep.match_subscription` (31 + 7), `ep.commit_offset`
(7 + 2), `ep.refresh_member` (3). Ids are stable; a few numbers are retired (size budget), so gaps are expected.
Input and output fields: `reference/processing-rules.md` §11. Run with
`python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --areas ep --impl-cmd "<your adapter>"` (adapter
protocol: `reimplementation-kit` reference/adapter-protocol.md). Profiles: 74 `both`, 42 `compat`, 35 corrected
twins (`…x`). Every compat/both expectation was produced by the reference packages (evidence `EXECUTED` by
`ep-oracle`) except the three `ep.refresh_member` vectors: the reference reads its own wall clock, so the
ep-oracle checks the bucket rule on a live flag write and applies it to `now_unix` (`RECOMPUTED`, with a note);
corrected twins are `RECOMPUTED` from their RBD.

## 10. Implementer gotchas

<!-- evidence-check: off implementer guidance derived from the EP rules and EPC scenarios cited inline -->

1. Decode `properties` with a literal-preserving JSON reader if you target corrected values; do NOT decode the
   whole record with a mode that turns numeric timestamps into an unsupported type.
2. Retry only the failed side effect; never re-produce a record that already succeeded (EPC-17 `no_dup`).
3. Commit only the prefix of records that have a disposition; a later batch must never commit past an earlier
   record that has none (the reference's main loss mode).
4. `exec` your process in wrappers (signals, exit status); exit non-zero quickly on an empty broker list.
5. Size the database pool below the role's connection limit (EPC-30).
6. Use exact (organization, external id) equality for subscriptions; truncate both bounds and the event time to
   milliseconds; compare UTC instants.
7. CDC rows: decide what an absent column means; never let it silently reset `pay_in_advance` or `recurring`.
8. The suite does not observe a retry topic yet (KQ-1): make in-place retries absorb one-shot faults.

<!-- evidence-check: on -->

## 11. Scripts

| Command | Purpose | Observed (2026-10-02) |
|---|---|---|
| `bash .claude/skills/events-processor-spec/scripts/run-suite.sh --impl-cmd CMD --mode db --profile both` | black-box suite | Go reference: `run-suite: scenarios=31 failing=12 unruled=1 skipped=4 mode=db profile=both … exit=3` |
| `bash .claude/skills/events-processor-spec/scripts/run-suite.sh --impl-cmd CMD --mode cache --profile both` | same, memory-cache mode | Go reference: `scenarios=27 failing=7 unruled=2 skipped=8 mode=cache` |
| `python3 .claude/skills/events-processor-spec/scripts/gen-scenarios.py --check` | scenarios and assertions match their generator | `gen-scenarios --check: scenarios=35 assert_files=22 drift=0` |
| `python3 .claude/skills/events-processor-spec/scripts/gen-scenarios.py --check-corpus .claude/skills/event-accounting-campaign/scripts/value-corpus/corpus.tsv` | corpus sync | `corpus-sync: OK rows=27` |
| `python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --areas ep --impl-cmd CMD` | unit vectors | ep-oracle: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=116 passed=116 skipped_ops=0 exit=0` |
| `scripts/maintainer/*` | MAINTAINER-ONLY (excluded from clean-room packs): `build-go-reference.sh` (reference binary + ep-oracle from the repository), `regen-goldens.sh` (three-pass re-mint with reviewed diff), `mint-ep-units.py` (unit vectors), `selftest-iut.py` (Python self-test IUT) | see `reference/conformance-suite.md` §11 |

## 12. Provenance and maintenance

- Pins: events-processor tree `83e012866f29`; billing peers at lago-api `591ae90`. Goldens were minted from the
  reference binary and confirmed by three full passes per mode; unit vectors by the ep-oracle (reference
  packages behind the adapter protocol). Rule-level citations live in each chapter's "Provenance (maintainers)".
- Update triggers: an events-processor change that touches decoding, time, value, matching, outputs, commits or
  the cache → `maintainer/regen-goldens.sh` (three passes, reviewed diff) and `maintainer/mint-ep-units.py --write`; an
  owner ruling on a `proposed` RBD → flip the assertion's `ruling` and the twin vectors; a retry-topic decision
  (KQ-1) → seed and observe the retry topic in the runner and add a RETRIED ledger class; the production CDC
  column list (OD-1b) → re-rule EPC-31.
- Open questions affecting this skill (owner questions OD-22 and OD-1b; register in `reimplementation-kit` SKILL.md
  section 12): KQ-1 (retry topic names), KQ-2 (production CDC configuration), KQ-4 (age
  of records without `ingested_at`), KQ-5 (dead-letter codes for undecodable records), KQ-6 (byte-level vs
  canonical output), KQ-14 (broker emulator fidelity for other client libraries).
