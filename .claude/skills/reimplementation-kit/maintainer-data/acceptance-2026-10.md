<!-- MAINTAINER-ONLY: clean-room acceptance record; never in a clean-room pack (maintainer-data/ is stripped). -->
# Clean-room acceptance record, kit 1.0.0 → 1.6.0 (2026-10-02 .. 2026-10-05)

The owner report required by `reference/acceptance-and-grading.md` §6: pass rates per component, the defect list and a
summary of the gap logs, for the acceptance runs of the re-implementation kit. Pins: lago-api `591ae9005110`,
events-processor tree `83e012866f29`. Implementer model class: Sonnet-class remote sessions.

## 1. Verdict

**Accepted on kit 1.6.0** (kit commit `92dcd7a`, clean-room pack `288a8f0`). Twelve independent implementations of the
nine components, each built in a fresh session from the clean-room pack alone with no access to the Lago source, meet
every threshold on shipped and holdout vectors in both profiles (§13). Every shipped vector of every area passes in
both profiles; proposed corrected twins are graded UNRULED. Five holdout vectors still fail in one implementation each.
All five are classified IMPL, and each implementation stays within its holdout threshold. The events-processor
implementation passes 100 % of the decided assertions of the corrected suite run. Every exit criterion of §6 is met:
0 open K-VEC and 0 known open K-SPEC (§14).

Acceptance took six implementation runs and six fix rounds (kit 1.1.0 to 1.6.0). The last four rounds dealt with a
single rule: how a binary64 value is stored in a 5-place decimal column. The shipped vectors did not determine that
rule until probes on the reference from 2^36 (about 6.87 × 10^10) up settled it. The last point (FR-7) came from the
transcript audit's review of the code, not from a failing vector, and needed no re-run. The remaining open items are
owner decisions: rulings on the proposed corrected twins (OD-21), OD-1b and OD-23 (§15).

## 2. Protocol

- **Isolation: option A** (owner decision OD-24, 2026-10-02).
  - The pack (`kit-pack.sh --cleanroom`) has no maintainer tooling, no holdout and no `maintainer-oracle.md`. It is
    committed on the pack-only branch `kit-pack-v1`.
  - Each implementer is a fresh remote session that clones only its own branch `kit-cr/<id>`, created from the pack,
    at depth 1.
  - Deny rules block git fetch, clone and checkout of other refs, as well as curl, wget, web tools and GitHub tools.
    The only network egress allowed is to package indexes (PyPI, Go proxy).
  - From run 3 on, each session is pinned to the exact pack commit (`source_revision` = SHA, §7).
- **Implementations:** twelve, covering nine components:
  - CRC-1 domain (crc-1);
  - CRC-2 pricing (crc-2a, crc-2b);
  - CRC-3 events and expression (crc-3);
  - CRC-4 aggregation (crc-4a, crc-4b);
  - CRC-5 periods (crc-5);
  - CRC-6 invoice and credit notes (crc-6a, crc-6b);
  - CRC-7 wallets, progressive billing and alerts (crc-7);
  - CRC-8 API, webhooks and clock (crc-8);
  - CRC-9 events-processor (crc-9).

  All are written in Python 3.12, from the brief of §4.2.
- **Grading,** by the lead on a worktree of the pushed branch with a fresh venv:
  - `kitrun.py --profile compat` and `--profile corrected`, both with `--include-holdout maintainer-data/holdout`
    (holdout seed `lago-kit-holdout-v1`, a 20 % stratified split);
  - for crc-9, also `run-suite.sh` twice: a corrected run with the default configuration, and a compat run with
    `--impl-env EP_PROFILE=compat --loose-errors` (§2.1).

  Thresholds come from `acceptance/thresholds.json`.
- **Audit:** every session's transcript is audited (`list_events`, every tool call and its result), and every pushed
  diff is scanned.
- **Fix loop (§5):**
  1. Kit defects found in the gap logs, or by the lead's checks, are fixed in a new kit version.
  2. The pack is rebuilt.
  3. Implementations that are below a threshold, or that fail vectors added for their areas, re-run on the new pack.

  Fix rounds are numbered as in the lead's working notes for the acceptance: FR-2 to FR-7 produced kit 1.1.0 to
  1.6.0, and the `SKILL.md` changelog calls them the first to the sixth fix round. Labels used during authoring, before
  acceptance, are unrelated.

## 3. Run 1: kit 1.0.0 (2026-10-02, pack `1b6b96e` from kit commit `577b18d`)

Twelve sessions ran, one per implementation, each with the full brief. Compat rates in the table below are passed out
of graded, on shipped and on holdout vectors. The corrected runs also met every threshold, with the proposed twins
graded UNRULED.

| Impl | Component and areas | Compat shipped | Compat holdout | Verdict |
|---|---|---|---|---|
| crc-1 | CRC-1 domain | 119/119 | 29/29 | PASS |
| crc-2a | CRC-2 pricing | 249/249 | 66/66 | PASS |
| crc-2b | CRC-2 pricing | 249/249 | 65/66 (98.5 %) | PASS |
| crc-3 | CRC-3 events; expression | 60/60; 71/71 | 17/17; 18/18 | PASS |
| crc-4a | CRC-4 aggregation | 194/194 | 46/46 | PASS |
| crc-4b | CRC-4 aggregation | 194/194 | 46/46 | PASS |
| crc-5 | CRC-5 periods | 189/189 | 50/51 (98.0 %) | PASS |
| crc-6a | CRC-6 invoice; credit_notes | 114/114; 31/31 | 26/28 (92.9 %); 8/8 | PASS |
| crc-6b | CRC-6 invoice; credit_notes | 114/114; 31/31 | 28/28; 8/8 | PASS |
| crc-7 | CRC-7 wallets; progressive; alerts | 73/73; 45/45; 21/21 | 19/19; 11/11; 6/6 | PASS |
| crc-8 | CRC-8 api; webhooks; clock | 34/34; 37/37; 10/10 | 8/8; 8/8; 2/2 | PASS |
| crc-9 | CRC-9 events-processor | ep 116/116; suite corrected 21 PASS, 0 failing, startup 4/4; compat 30/30 MATCH | (no `ep` holdout) | PASS |

Four compat holdout vectors failed:

- crc-2b: `pricing.true_up.004`;
- crc-5: `periods.subscription_fee.023`;
- crc-6a: `invoice.commitment.002` and `invoice.void.005`.

The FR-2 triage classified all four as IMPL: the rule is stated, and where the component has a second implementer, that
implementer passes the vector.

**Audit (2026-10-02, all 12 transcripts, 909 events, 319 tool calls).**

- **Isolation held.** No session attempted a forbidden operation, no call was denied, every push went to the session's
  own branch, and no session reached any Lago source.
- **The rule "never read `expected` programmatically" was broken** by 10 of the 12 sessions, 7 of them heavily:
  - crc-3, crc-6a and crc-8 printed every vector of their areas, with its expected value, before writing code;
  - crc-2a printed 80 % of its vectors, crc-6b 88 %, crc-4b 71 % and crc-4a 47 %;
  - crc-1 and crc-9 were essentially compliant.
- **No session copied** vector ids or expected values into its code.
- **Consequence:** for run 1 the holdout rates, not the shipped rates, are the meaningful measure. All twelve
  implementations met the holdout thresholds.

**Gap logs.** 98 numbered entries, all classified in fix round FR-2: 54 K-SPEC, 26 K-FMT, 6 K-VEC and 12 IMPL.

## 4. Fix round FR-2 → kit 1.1.0 (2026-10-05, commit `5c96a62`)

**Method.** Six fixer groups, each followed by an independent verifier, then an integration check and a completeness
critic. Every new claim about the reference was executed on the oracle before it was written.

**Changes:**

- 138 vectors added, none removed;
- six `both` vectors became `compat`, each with a corrected twin;
- `pricing.gp.007` asserts one more field.

Lead decision applied: an oracle-correct vector is never dropped or weakened to protect an implementation's score.

**Critic verdict:** 0 open K-VEC and 2 open minor K-SPEC, which is within the exit criterion:

- KS-FR2C-1, the current-usage period ratio;
- KS-FR2C-2, the columnar prorated-sum conversion.

**Re-grade** of the unchanged run-1 code on 1.1.0. No previously graded vector changed result. Seven implementations
fell below a threshold, and only through vectors new in 1.1.0. In most cases the new vector pinned exactly the
assumption the implementer had logged as a gap.

| Impl | Area below threshold |
|---|---|
| crc-1 | domain 97.6 % |
| crc-2a | pricing 97.0 % |
| crc-2b | pricing 97.0 % |
| crc-3 | expression 91.8 % |
| crc-6a | invoice 93.4 %; credit_notes 92.7 % |
| crc-6b | credit_notes 90.2 % |
| crc-8 | clock 70.6 %; webhooks 85.2 % |

## 5. Run 2: fix loop on kit 1.1.0 (2026-10-05, pack `b202421`)

The seven implementations below a threshold re-ran in fresh sessions on their own branches, with the 1.1.0 pack and a
binding method:

- work from the cited rules;
- read one failing vector at a time;
- never dump expected values.

Sessions took 47 s to 2 min 2 s from prompt to final message. Three REPORT.md files state 10 to 30 minutes; the
transcripts show otherwise.

| Impl | Areas | Compat shipped | Compat holdout | Corrected (graded) | Verdict |
|---|---|---|---|---|---|
| crc-1 | domain | 123/123 | 29/29 | 122/122 | PASS |
| crc-2a | pricing | 263/263 | 66/66 | 238/238 | PASS |
| crc-2b | pricing | 263/263 | 65/66 | 238/238 | PASS |
| crc-3 | events; expression | 62/62; 85/85 | 17/17; 18/18 | 56/56; 84/84 | PASS |
| crc-6a | invoice; credit_notes | 137/137; 41/41 | 26/28; 8/8 | 132/132; 37/37 | PASS |
| crc-6b | invoice; credit_notes | 137/137; 41/41 | 28/28; 8/8 | 132/132; 37/37 | PASS |
| crc-8 | api; webhooks; clock | 36/36; 54/54; 17/17 | 8/8; 8/8; 2/2 | 34/34; 53/53; 16/16 | PASS |

The holdout failures are the same IMPL vectors as in run 1.

**Audit: 321 events, 117 tool calls.**

- No forbidden operations, no denied calls, pushes only to the sessions' own branches, and commits only under
  `impl/<id>/`.
- Six sessions read only their own failing vectors.
- crc-6a ran one grep across a whole op, which also showed the expected values of 5 passing vectors. That makes about
  11 vectors in all, 6 % of its areas.
- Code diffs: the changes are general rule changes. The only tables added (the currency list and the webhook catalogue)
  are copied from the spec text, not from vectors.

The v1.1 gap logs raised 17 further questions. Those questions, together with KS-FR2C-1 and KS-FR2C-2, were the input
of FR-3.

## 6. Fix round FR-3 → kit 1.2.0 (2026-10-05, commit `758480e`)

Two fixer groups worked in parallel, one on chapters 01, 04, 05 and 13 and one on chapters 02, 03, 07 and 08; the lead
integrated the shared files. Every question in the v1.1 gap logs was classified, as were the two items 1.1.0 left
open. Each behaviour claim was executed on the oracle, with the ClickHouse probes run under the lock.

| Source | Question | Class | Resolution |
|---|---|---|---|
| crc-1 | `to_minor_units` for a non-accepted currency | ANSWERED | BE-DM-24 already says such a code never reaches it and the result is not graded |
| crc-2a | 10-place unit rounding of `already_billed_units`; 15-place rate in the corrected profile | K-SPEC minor | BE-PR-71: already-billed units used as given; BE-PR-87: scales hold in both profiles |
| crc-2a | projection ratio for grouped charges, corrected profile | ANSWERED + clarified | BE-PR-41: every group uses the same binary64 ρ; `pricing.projection.010` |
| crc-2b | NUM-OUT warning on echoed JSON-float bounds | ANSWERED (K-FMT note) | BE-PR-58, `vector-format.md` §4.1 and grading §3: the warning is expected there |
| crc-2b | BE-PR-41 when days(from, to) ≤ 0 | K-SPEC → not reachable | stated as not reachable and not graded (oracle: fails at now = from) |
| crc-2b | 15-place rounding of the `pricing_unit` op record | K-SPEC minor | BE-PR-87 covers it; `pricing.pricing_unit.008` |
| crc-3 | member checks for a hand-built `event` on the processor surface | K-FMT | schema and BE-EX-40; `expression.ep.022` |
| crc-3 | BE-EV-44: flagged events' keys as "earlier" keys | ANSWERED | BE-EV-43 wording; the reading cannot change a result (3 probes) |
| crc-6a | position of the upgrade + refund/offset `server_error` among the "no note" exits | K-SPEC (assumption refuted) | BE-CN-18 lists the four exits in order; `credit_notes.termination.013`..`.015` |
| crc-6a, crc-6b | `expiration_at` check conditional on `time_limit`? | K-SPEC (clarified) | BE-IV-17: whatever `expiration` says; `invoice.coupon_create.017` |
| crc-6a, crc-6b | `applied_before` entries without `coupon` | K-FMT | schema description; already pinned by `invoice.coupon_apply.005`, `.006`, `.013` |
| crc-6a | value checks of a percentage coupon's amount and currency, also on apply | ANSWERED (create) / K-SPEC (apply) | BE-IV-18 "whatever the coupon type"; `invoice.coupon_create.016`, `invoice.coupon_apply.016`, `.017` |
| crc-6b | `status: voided` the only voided marker | ANSWERED | schema; BE-CN-18 adds "payment status plays no part" |
| crc-6b | how `dec16` rounds | K-SPEC | a cut of the shortest text after 16 significant digits, never a rounding; `credit_notes.compute.019`, `019x` |
| crc-8 | `jobs_due` window and a fractional start | ANSWERED (window) / K-SPEC (fraction) | BE-CK-2: whole-second ticks, period from the previous run cut to the second, `[from, to)`; fractional `from` not graded |
| KS-FR2C-1 | period ratio of the current-usage fee path | K-SPEC | new BE-PR-88 (prose only: forcing other values changed no fee or projection on the oracle) |
| KS-FR2C-2 | columnar decimal→binary64 conversion and summation order | K-SPEC | BE-AG-74 states the conversion (model matched 4,009/4,009 random values on ClickHouse 26.2 x86-64) and that the order is undefined; `aggregation.store_ch.prorated.005`, `.006` and twins |
| FR-2 critic | void near-tie candidate; maintainer model rounding void items through text | vector + tool fix | `invoice.void.009`; `recompute-invoicing.py` uses round5 and the dec16 cut |

**Vectors:** 17 added, none changed or removed.

- By profile: 11 `both`, 3 `compat` and 3 corrected twins.
- By evidence: 14 EXECUTED and 3 RECOMPUTED.

**Kit gates on 1.2.0:**

| Gate | Result |
|---|---|
| validator `--gate --rule-coverage` | 0 errors, 0 warnings (1,984 vectors, 76 scenarios) |
| every billing `both`/`compat` vector, shipped and holdout, on the oracle | 1695/1695 |
| scenario replay on the oracle | 76/76 |
| `ep` vectors on the ep-oracle | 120/120 |
| kit self-test | 7/7 |
| provenance | 0 broken references |
| clean-room pack | 0 forbidden files; validator 0 errors inside the pack |
| `kit.json` check | 0 changed |

Open after FR-3: 0 K-VEC and 0 known K-SPEC.

## 7. Run 3: fix loop on kit 1.2.0 (2026-10-05, pack `a8bcb67`)

**Who re-ran:**

- crc-6a, because credit_notes was at 93.3 %, below the 95 % threshold;
- crc-4a, crc-4b, crc-5, crc-6b, crc-7 and crc-9, which met the thresholds but failed vectors added in 1.1.0 or 1.2.0.

**Method:** the same as in run 2, with `kitrun --only` for single-vector diffs and the wall-clock time taken with
`date -u`.

**Stale checkouts.** The first crc-6a and crc-6b sessions received a stale checkout of their branch: an earlier state,
not the 1.2.0 pack commit.

- crc-6b stopped and asked.
- crc-6a's push was rejected, and its `git fetch` was then denied by the isolation rules.
- Neither pushed anything.

Both were replaced by sessions pinned to the exact pack commit.

| Impl | Areas | Compat shipped | Compat holdout | Corrected (graded) | Verdict |
|---|---|---|---|---|---|
| crc-4a | aggregation | 206/206 | 46/46 | 171/171 | PASS |
| crc-4b | aggregation | 206/206 | 46/46 | 171/171 | PASS |
| crc-5 | periods | 196/196 | 50/51 | 179/179 | PASS |
| crc-6a | invoice; credit_notes | 142/142; 45/45 | 26/28; 8/8 | 137/137; 40/40 | PASS |
| crc-6b | invoice; credit_notes | 142/142; 45/45 | 28/28; 8/8 | 137/137; 40/40 | PASS |
| crc-7 | wallets; progressive; alerts | 78/78; 46/46; 22/22 | 19/19; 11/11; 6/6 | 77/77; 46/46; 18/18 | PASS |
| crc-9 | ep; conformance suite | ep 120/120; suite compat run 30/30 MATCH | — | ep 108/108; suite corrected run 21 PASS, 0 failing, startup EPC-26..29 4/4 | PASS |

- crc-4a and crc-4b implemented the columnar conversion of BE-AG-74 from the chapter text alone, and both pass the two
  new `aggregation.store_ch.prorated` vectors.
- crc-6a implemented the BE-CN-18 exit order that its earlier assumption had contradicted.

**Audit: 7 sessions plus the 2 superseded ones; 316 events, 115 tool calls.**

- **Isolation.** No forbidden operations were attempted. Every push went to the session's own branch, and every commit
  touched only `impl/<id>/`, with one exception:
  - crc-7's `git add -A` also committed the bytecode cache of the kit's `scripts/adapter_ref.py` (one `.pyc` under
    `scripts/__pycache__/`). That is a generated file, not a source or rule change.
- **One denied call:** crc-6a's `git checkout -p --`, an interactive restore of its own working tree that named no ref.
- **Reading discipline.**
  - Five sessions read raw vector lines only for their failing vectors, and crc-6b read none at all.
  - crc-6a ran a rule-text grep that also covered the vectors directory. It printed 4 passing termination vectors
    (about 2 % of its areas), and the session then narrowed the grep to `*.md`.
- **Code.** No vector ids, expected values, or tables keyed by vector inputs in any diff.
- **Gaps.** The v1.2 gap logs hold two entries, from crc-6a and crc-6b, both on the same BE-CN-7 sentence. They are
  the input of FR-4.

Earlier, on the 1.2.0 tree, the lead re-graded all twelve implementations. After run 3, all of them passed every
shipped vector of their areas in both profiles.

## 8. Fix round FR-4 → kit 1.3.0 (2026-10-05, commit `40904ed`)

**The gap.** Both run-3 gap entries concern one sentence of BE-CN-7: the note's precise taxes are "stored by rounding
its text to 5 places". Rounding the text fails `credit_notes.compute.009`, so the two implementers read the sentence
differently:

- crc-6a stored a 16-significant-digit rounding;
- crc-6b used `round5` of BE-IV-14.

Both pass every vector of 1.2.0. Classification: K-SPEC, because the rule text contradicted a shipped vector.

**Probes.** Probes through `oracle.sh adapter`, with amounts above 10^11, separated the readings:

| Value | Reference stores | `round5` alone |
|---|---|---|
| void item 102880657510.79861 | 102880657510.7986 | keeps every digit |
| note precise taxes 216049380771.60492 | 216049380771.6049 | keeps every digit |
| note precise taxes 171802469353.58026 | 171802469353.5803 | keeps every digit |

The reference's decimal-column cast rounds a float to the column scale, keeps 16 significant digits, then scales to 5
places. Below 10^11 that is `round5` alone.

**Changes.**

- The column rule is now stated in three places: the chapter 07 notation paragraph (which had said `round5` for every
  binary64 stored at 5 places), BE-IV-42 and BE-CN-7.
- `invoice.void.010` and `credit_notes.compute.020` (EXECUTED, `compat`, RBD-68) pin the rule, each with an exact twin.
- The maintainer model applies the rule.
- The billing unit size cap rose from 1,400,000 to 1,450,000 bytes, because the four new vectors exceeded it by 239
  bytes.

**Gates on 1.3.0:**

- validator: 0 errors, 0 warnings (1,988 vectors);
- invoice and credit-note `both`/`compat` vectors on the oracle, with holdout: 225/225 (the other areas and the oracle
  modules are unchanged since the 1.2.0 gate run);
- self-test 7/7; provenance 0 broken; pack forbidden 0; `kit.json` changed 0.

**Effect on the implementations.** Only crc-6a and crc-6b were affected, and both stayed above the thresholds:

- crc-6a fails `invoice.void.010` (its note taxes already used 16 digits);
- crc-6b fails both new vectors.

## 9. Run 4: fix loop on kit 1.3.0 (2026-10-05, pack `f7bc470`)

crc-6a and crc-6b re-ran on the 1.3.0 pack in sessions pinned to the pack commit. They used the run-3 method: one
failing vector at a time, with rule text searched in the chapters only.

| Impl | Areas | Compat shipped | Compat holdout | Corrected (graded) | Verdict |
|---|---|---|---|---|---|
| crc-6a | invoice; credit_notes | 143/143; 46/46 | 26/28; 8/8 | 137/137; 40/40 | PASS |
| crc-6b | invoice; credit_notes | 143/143; 46/46 | 28/28; 8/8 | 137/137; 40/40 | PASS |

Both built the column rule from the chapter 07 notation paragraph as one helper (`round5`, then 16 significant
digits, then 5 places), applied to void items and to the note's precise taxes. Neither logged a new gap.

**Audit: 63 events, 22 tool calls, all Bash.** crc-6a took 45 s and crc-6b 1 min 14 s from prompt to final message.

- **Isolation and reading.**
  - No forbidden operations and no denied calls.
  - Every push went to the session's own branch, and every commit touched only `impl/<id>/`.
  - Neither session read a vector file. The only expected values shown were the kitrun diff of one failing vector.
- **Caveat: the column rule was still underdetermined.** The audit compared the two final column-rule functions on
  20,000 random inputs per magnitude band:
  - below about 4.5 × 10^10 they gave identical results;
  - in [4.5 × 10^10, 9 × 10^10) they differed on 91.3 % of inputs;
  - above 10^11 they differed on 3 % to 7 % of inputs.

  Both still passed every shipped vector, so the vectors did not separate them. Neither session logged it. This
  started FR-5.

## 10. Fix round FR-5 → kit 1.4.0 (commit `8eadb23`) and run 5 (pack `e1647be`)

**Classification:** K-SPEC. The rule text did not determine the result in the band where the run-4 implementations
diverge.

**What the reference does.** The pinned Ruby and the reference show that `round5`'s correction step adds 0.5 in
binary64:

- from `f ≥ 2^52` (x ≥ about 4.5 × 10^10), `f ⊕ 0.5` rounds to an even neighbour;
- so an even `f` is raised by one: 47033384975.09552 is stored as 47033384975.09553.

**Changes.**

- BE-IV-14 writes the correction with ⊕.
- `invoice.void.011` (EXECUTED, `compat`, RBD-68) and its exact twin `.011x` pin it.
- The maintainer model `recompute-invoicing.py` had used `floor(x + 0.5)`, which is wrong from 2^52 up. It now rounds
  the exact product half away.

**Gates on 1.4.0:**

- validator 0/0 (1,990 vectors);
- invoice and credit-note vectors on the oracle, with holdout: 226/226;
- self-test 7/7; provenance 0 broken; pack forbidden 0; `kit.json` changed 0.

**Effect on the implementations.**

- crc-6a (head `c23c7fb`) raised every `f` from 2^52 up, so it passed every 1.4.0 vector.
- crc-6b skipped the correction when `f + 0.5 = f`, so it failed `invoice.void.011`.

Run 5 re-ran crc-6b alone, pinned to its 1.4.0 pack commit `58b4426`.

| Impl | Head | Areas | Compat shipped | Compat holdout | Corrected (graded) | Verdict |
|---|---|---|---|---|---|---|
| crc-6b | `6f44f42` | invoice; credit_notes | 144/144; 46/46 | 28/28; 8/8 | 137/137; 40/40 | PASS |

crc-6b made two changes:

- it made the correction a binary64 sum;
- it moved its 16-digit step from the shortest text to the binary64 value. With the first change alone,
  `invoice.void.010` regressed.

Its v1.4 gap log holds one interpretation note, not a question: the 16-digit step applies to the exact binary64 value,
not to its shortest text. The lead first classified it ANSWERED, citing the notation paragraph and `invoice.void.010`.
That was wrong: the run 5–6 audit showed that a shortest-text variant also passes every shipped vector, so the note
named an open K-SPEC point. FR-7 closed it (§12).

## 11. Fix round FR-6 → kit 1.5.0 (commit `0463b25`) and run 6 (pack `38da401`)

**Method.** Following the run-4 lesson, the lead cross-checked the column-rule and `round5` functions of both heads
against the maintainer model, on random inputs in every magnitude band, exact binary64 ties included.

**Findings.** Three behaviours were open. Each was settled with probes through `oracle.sh adapter` (14 probe vectors in
all).

| Behaviour on the reference | Example | Implementation that differed |
|---|---|---|
| an exact tie at the 16th significant digit goes to the even digit | 256924291381.03125 → 256924291381.0312 | both rounded half up |
| from 2^52 up, an odd `f` is kept | 72606570804.87341 | crc-6a raised every `f` |
| a note-tax case of the column rule | 171802469353.58026 → 171802469353.5803 | crc-6b, which folded the per-code tax base into binary64 where BE-CN-7 keeps it exact |

Classification: K-SPEC. The text did not cover ties, and it did not spell out what ⊕ means for odd and even `f`.

**Vectors:** 5 added, none changed or removed:

- `invoice.void.012`, `both` (profile-neutral);
- `invoice.void.013`, `compat`, with its twin `.013x`;
- `credit_notes.compute.021`, `compat`, with its twin `.021x`.

**Gates on 1.5.0:**

- validator 0/0 (1,995 vectors);
- invoice and credit-note vectors on the oracle, with holdout: 229/229;
- the maintainer model matches the vectors in both profiles;
- self-test 7/7; provenance 0 broken; pack forbidden 0; `kit.json` changed 0.

**Effect on the implementations, graded before the run on 1.5.0:**

- crc-6a fails `invoice.void.012` and `.013`;
- crc-6b fails `credit_notes.compute.021` and `invoice.void.013`.

Run 6 re-ran both, on branches carrying the 1.5.0 pack.

| Impl | Head | Areas | Compat shipped | Compat holdout | Corrected (graded) | Verdict |
|---|---|---|---|---|---|---|
| crc-6a | `1118ecb` | invoice; credit_notes | 146/146; 47/47 | 26/28; 8/8 | 138/138; 40/40 | PASS |
| crc-6b | `47318f2` | invoice; credit_notes | 146/146; 47/47 | 28/28; 8/8 | 138/138; 40/40 | PASS |

**Cross-check after run 6.** 230,000 random inputs, 20,000 of them exact ties, gave 0 differences between either
implementation and the model. All 14 probes pass on both. Neither session logged a gap.

**Audit (runs 5 and 6): 117 events, 42 tool calls, all Bash.** Run 5 (crc-6b) took 1 min 26 s from prompt to final
message; in run 6, crc-6a took 43 s and crc-6b 1 min 19 s. Every REPORT.md time is a `date -u` measurement that matches
the transcript.

- **Isolation.** No forbidden operations and no denied calls. Each session pushed one commit to its own branch, and
  each commit touches only `impl/<id>/`.
- **Reading discipline.** No session read a vector file. The only expected values shown were kitrun diffs of failing
  vectors:
  - run 5: `invoice.void.011`, and `.010` after the session's own edit broke it;
  - run 6, crc-6b: `credit_notes.compute.021`;
  - run 6, crc-6a: none.

  There were two light departures. Two recursive rule-text greps also covered `billing-engine-spec/SKILL.md`, and each
  printed one line from it. Some diffs came from filtered full runs instead of `--only`.
- **Code.** General rule changes only: BE-IV-14's binary64 correction, half-away rounding of the product, the column
  rule's tie to even, and BE-CN-7's exact base. No vector ids, example operands or lookup tables.
- **Finding: the column rule was still underdetermined.** The text did not say whether the 16-digit step rounds the
  exact binary64 value or its shortest text. Both implementations chose the exact value. The two readings differ on
  about 8 % of amounts in [2^36, 10^11) and on 4 % to 5 % above, and a shortest-text variant also passes all 193
  shipped vectors of the two areas. This started FR-7.

## 12. Fix round FR-7 → kit 1.6.0 (kit commit `92dcd7a`, pack `288a8f0`)

**Classification:** K-SPEC.

- The text did not say which value the 16 digits are taken from.
- Chapter 07's sentence "below 10^11 this is `round5` alone" was wrong in [2^36, 10^11).
- The lead's earlier ANSWERED classification of crc-6b's v1.4 note (§10) was a misclassification.

**Probes.** The lead searched void inputs where the two readings differ and ran eight of them, all from 2^36 up,
through `oracle.sh adapter`. The reference matches the exact-value reading on all eight, for example:

| Void item | Exact-value reading (reference) | Shortest-text reading |
|---|---|---|
| 78096345254.9564 | 78096345254.95641 | 78096345254.9564 |
| 820741212006.6481 | 820741212006.6479 | 820741212006.648 |

As a negative control, the same eight probes with the text reading's values as expected fail on every one.

**Changes.**

- The chapter 07 notation paragraph now says that the 16 digits are those of the exact binary64 value of `round5`'s
  result, and that "`round5` alone" holds below 2^36 (about 6.87 × 10^10), not below 10^11. BE-IV-42 and BE-CN-7 say
  the same.
- 3 vectors added, none changed or removed:
  - `invoice.void.014`: EXECUTED, `both` (the exact quotient stores the same value);
  - `invoice.void.015`: EXECUTED, `compat`, RBD-68;
  - `invoice.void.015x`: the exact twin of `.015`.
- The maintainer model already rounded the exact value; only its docstring changed.

**Gates on 1.6.0:**

- validator `--gate --rule-coverage`: 0 errors, 0 warnings (1,998 vectors);
- invoice and credit-note vectors on the oracle, with holdout: 231/231;
- maintainer model: 0 failing in both profiles (the `invoice.commitment` op is not modelled and is skipped);
- self-test 7/7 (compat 1529/1529, corrected 1407/1407);
- provenance 0 broken (2,074 vectors); pack forbidden 0, validator 0 errors inside the pack (1,673 vectors);
  `kit.json` changed 0; evidence check flagged 0 on the edited chapters.

**Effect on the implementations: none.** crc-6a and crc-6b already round the exact value, pass both new vectors, and
needed no re-run. An implementation that rounds the shortest text now fails `invoice.void.014` and `invoice.void.015`.

## 13. Final standing on kit 1.6.0

The lead graded each implementation's latest pushed head on 2026-10-05 against the kit 1.6.0 tree, holdout included.

| Impl | Head | Areas | Compat shipped | Compat holdout | Corrected shipped (graded) | Corrected holdout (graded) | Verdict |
|---|---|---|---|---|---|---|---|
| crc-1 | `6bc1fa1` | domain | 123/123 | 29/29 | 122/122 | 29/29 | PASS |
| crc-2a | `3a58a47` | pricing | 265/265 | 66/66 | 240/240 | 64/64 | PASS |
| crc-2b | `c6fac00` | pricing | 265/265 | 65/66 | 240/240 | 63/64 | PASS |
| crc-3 | `2b1b9b2` | events; expression | 62/62; 86/86 | 17/17; 18/18 | 56/56; 85/85 | 16/16; 18/18 | PASS |
| crc-4a | `16d2405` | aggregation | 206/206 | 46/46 | 171/171 | 40/40 | PASS |
| crc-4b | `eaf08de` | aggregation | 206/206 | 46/46 | 171/171 | 40/40 | PASS |
| crc-5 | `cf9179c` | periods | 196/196 | 50/51 | 179/179 | 50/51 | PASS |
| crc-6a | `1118ecb` | invoice; credit_notes | 148/148; 47/47 | 26/28; 8/8 | 139/139; 40/40 | 26/28; 8/8 | PASS |
| crc-6b | `47318f2` | invoice; credit_notes | 148/148; 47/47 | 28/28; 8/8 | 139/139; 40/40 | 28/28; 8/8 | PASS |
| crc-7 | `3a5e354` | wallets; progressive; alerts | 78/78; 46/46; 22/22 | 19/19; 11/11; 6/6 | 77/77; 46/46; 18/18 | 19/19; 11/11; 6/6 | PASS |
| crc-8 | `12066e4` | api; webhooks; clock | 36/36; 54/54; 17/17 | 8/8; 8/8; 2/2 | 34/34; 53/53; 16/16 | 8/8; 8/8; 2/2 | PASS |
| crc-9 | `7d8c80b` | ep; suite | ep 120/120; suite compat run 30/30 MATCH | — | ep 108/108; suite corrected run 21 PASS, 0 failing, startup EPC-26..29 4/4 | — | PASS |

All 12 implementations pass every shipped vector of their areas in both profiles, with proposed twins UNRULED.

**Holdout misses.** Five vectors, each failing in one implementation only. All are classified IMPL, and each
implementation is within its holdout threshold.

| Impl | Vector | Since | Why IMPL |
|---|---|---|---|
| crc-2b | `pricing.true_up.004` | run 1 | the rule is stated; crc-2a passes it |
| crc-5 | `periods.subscription_fee.023` | run 1 | an adapter ERROR; classified IMPL in the FR-2 triage |
| crc-6a | `invoice.commitment.002` | run 1 | the rule is stated; crc-6b passes it |
| crc-6a | `invoice.void.005` | run 1 | the rule is stated; crc-6b passes it |
| crc-2b | `pricing.percentage.009`, corrected profile only | 1.1.0 | see below |

`pricing.percentage.009` is a `both` vector that crc-2b passes in compat. FR-2 made its running totals consistent in
1.1.0. Since then crc-2b has failed it in the corrected profile, giving 0 where 2.691 is expected:

- BE-PR-27 gives `free` = 10000, and BE-PR-28 gives `FC` = 2;
- the corrected walk of BE-PR-30 therefore frees the first 2 events and prices the third on its uncovered 90 units:
  90 × 2.99 / 100 = 2.691, the same as compat;
- crc-2b frees the first FE (3) events instead, as its own gap log states ("first FE events free");
- crc-2a passes the vector in both profiles.

The earlier sections of this record listed compat misses only. This one was found when the corrected misses of the
1.5.0 re-grade were reviewed.

**Holdout-versus-shipped gap:** at most 7.1 points (crc-6a invoice), under the 10-point overfitting flag of §4.3.

## 14. Exit criteria (acceptance-and-grading §6)

| Criterion | Status on kit 1.6.0 |
|---|---|
| CRC-1..CRC-9 meet their thresholds on shipped AND holdout sets | met: 12 of 12 implementations, both profiles (§13) |
| 0 open K-VEC | met: 0. Run 1 found 6, all fixed in 1.1.0; none since. FR-3 to FR-7 added vectors but corrected none |
| at most 3 open minor K-SPEC, each with a ticket | met: 0 known open. FR-2 left 2 minor items, closed in FR-3; FR-4 to FR-7 closed the column rule (FR-7 from the run 5–6 audit) |
| events-processor corrected profile: 100 % of decided assertions on the corrected run | met: crc-9 corrected run 21 PASS, 0 failing, startup EPC-26..29 4/4 (1.6.0 re-grade, identical to run 3) |
| a report for the owner: pass rates per component, defect list, gap-log summary | this record |

## 15. Open items (not blocking acceptance)

- **Owner rulings.**
  - Every corrected twin (117 billing, 4 `ep`) is `ruling: proposed` and graded UNRULED until the owner rules on the
    rebuild decisions: batch OD-21, items OD-21.1 to OD-21.64, including KQ-52 to KQ-56.
  - OD-1b (the production CDC broker configuration) remains open with the owner.
  - OD-23 (legal review of the kit and of the expression engine's licence; KQ-7, KQ-8) remains open with the owner.
- **Size budget.** Billing unit vectors use 1,411,838 of 1,450,000 bytes. A further fix round that adds many vectors
  needs the `kit_budget` raised (a lead decision, in `acceptance/thresholds.json`) or the vectors compacted.
- **Architecture coverage.** BE-AG-74's conversion model was verified on x86-64 builds of the columnar store (80-bit
  intermediate arithmetic). Other architectures are not verified.
- **Maintainer model.** `recompute-invoicing.py` does not model a trial in `credit_notes.termination`. No shipped vector
  needs it.
- **Holdout seed.** The same seed was used for all six runs. Runs 2 to 6 only re-ran implementers who never saw the
  holdout, so it stayed blind. A new acceptance run with new implementers rotates the seed (KQ-18).
- **Branch hygiene.** `kit-cr/crc-7` carries a generated `.pyc` of the kit's `adapter_ref.py` (run 3). It is harmless
  and is left as committed by the implementer.

## 16. Lessons for the next acceptance run

- **Pin each implementer session to the exact pack commit** (`source_revision` = SHA), not to the branch name. Two
  run-3 sessions received a cached earlier state of their branch.
- **Stop gate steps by recorded process id**, never by a name pattern, when a gate script runs in the background. A
  pattern stop let the replay start twice on one database, causing deadlocks and spurious errors. Re-run alone, the
  replay gave 76/76.
- **Do not trust self-reported times.** Run-2 reports said 10 to 30 minutes for sessions of under 2 minutes. Take the
  times from the transcripts, or from `date -u` in the session.
- **Keep the binding method.** Reading one failing vector at a time kept implementers on the chapter text from run 2
  on. The bulk reads of run 1 did not recur, except for two partial greps that also showed passing vectors (crc-6a in
  runs 2 and 3).
- **Cross-check implementations against the maintainer model on random inputs across magnitudes and on exact ties**,
  not only on the vectors. Two implementations that pass every vector can still disagree on most inputs in a band, as
  the column rule did between 4.5 × 10^10 and 10^11. That check found the K-SPEC items of FR-5 and FR-6; the gap logs
  did not.
- **Also compare against a literal reading of the text, not only against the maintainer model.** The model and both
  implementations agreed on FR-7's point. The audit's literal-reading variant showed that the text and the vectors
  left it open.
- **Test a claimed discriminating vector by running the other reading against it.** crc-6b's v1.4 note named the open
  point exactly, but it was classified ANSWERED on the strength of a vector that did not discriminate the two
  readings.
- **Review corrected-profile misses explicitly.** A corrected-only holdout miss (crc-2b) went unlisted for five runs,
  because the run summaries tracked compat rates.

## Provenance (maintainers)

- **Grading.**
  - Tool: `kitrun.py` with `--include-holdout maintainer-data/holdout`, per implementation, on a detached worktree of
    `origin/kit-cr/<id>`.
  - crc-9 is also graded with `events-processor-spec/scripts/run-suite.sh`: a corrected run with the default
    configuration, and a compat run with `--impl-env EP_PROFILE=compat --loose-errors`.
  - Dates: 2026-10-02 to 2026-10-05.
  - The final standing (§13) is a full re-grade of all twelve heads on kit 1.6.0, after a full re-grade on 1.5.0
    with the same results apart from the three vectors 1.6.0 added.
- **Kit gates.** The commands are in `SKILL.md` section 11.
  - 1.2.0 (`758480e`): full gate set, including oracle kitrun 1695/1695, scenario replay 76/76 and ep-oracle 120/120.
  - 1.3.0 (`40904ed`), 1.4.0 (`8eadb23`), 1.5.0 (`0463b25`) and 1.6.0 (`92dcd7a`): validator, oracle kitrun of the
    changed areas, maintainer model, self-test, provenance and pack scan.
- **Implementations.** The implementations and their KIT-GAPS and REPORT files are on the branches `kit-cr/<id>`.
- **Packs.** The packs are on the branch `kit-pack-v1`:

  | Kit version | Pack commit |
  |---|---|
  | 1.0.0 | `1b6b96e` |
  | 1.1.0 | `b202421` |
  | 1.2.0 | `a8bcb67` |
  | 1.3.0 | `f7bc470` |
  | 1.4.0 | `e1647be` |
  | 1.5.0 | `38da401` |
  | 1.6.0 | `288a8f0` (built from `25175d2`: the release commit `92dcd7a` minus two bytecode caches it had picked up) |
- **Re-verify:** re-run the grading above for any `kit-cr/<id>` head. The figures here are dated 2026-10-05.
