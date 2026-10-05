# Acceptance and grading

> Licence note: grading compares an implementation with recorded behaviour of lago-api (AGPL-3.0) at pin `591ae90`
> and of the Lago events-processor at tree `83e012866f29`; see `legal-and-provenance.md`.

What "conformant" means, how a rebuild is graded, how the kit itself is accepted by clean-room implementers, and how
a failing vector is triaged. Thresholds are machine-readable in `acceptance/thresholds.json` (kitrun reads them).

<!-- evidence-check: off normative grading policy; evidence = acceptance/thresholds.json and the kitrun/run-suite commands below -->

## 1. Components and thresholds

| Component | Scope | Graded by | Shipped | Holdout | Core |
|---|---|---|---|---|---|
| CRC-1 | money, time, numbering primitives | `kitrun --areas domain` | 100 % | 98 % | 100 % |
| CRC-2 | pricing engine (all charge models, pay-in-advance delta, fee money, true-up, pricing units, fixed charges, validation) | `--areas pricing` | 98 % | 95 % | 100 % |
| CRC-3 | expression evaluator, ingestion timestamp and validation | `--areas expression,events` | 98 % | 95 % | 100 % |
| CRC-4 | aggregation engine (PostgreSQL semantics mandatory, ClickHouse variant optional) | `--areas aggregation` | 95 % | 90 % | 100 % |
| CRC-5 | billing-period calculator | `--areas periods` | 98 % | 95 % | 100 % |
| CRC-6 | invoice totals, coupons, taxes, credit notes, lifecycle helpers | `--areas invoice,credit_notes` | 95 % | 90 % | 100 % |
| CRC-7 | wallets, progressive billing, alerts | `--areas wallets,progressive,alerts` | 95 % | 90 % | 100 % |
| CRC-8 | webhook encoder and signer, API helpers, clock | `--areas api,webhooks,clock` | 100 % | 98 % | 100 % |
| CRC-9 | events-processor (DB mode required; memory-cache mode graded when implemented) | separate runs per profile (§2.1): `run-suite.sh --profile corrected` + `run-suite.sh --profile compat --loose-errors` + `--areas ep` | corrected run: 100 % of decided assertions, startup contract EPC-26..29 4/4; compat run (migration-compat builds only): ≥ 90 % of DB goldens; `ep` units ≥ 95 % per profile | — | — |
| CRC-10 (stretch) | mini billing service behind `system.*` | `scenario-replay.py` | ≥ 60 % | — | — |

- RATE = PASS / (TOTAL − UNRULED); SKIP counts as not passed; CORE = pass rate on `core`-tagged vectors.
- Grading runs `--profile compat` for CRC-1..8 (the migration bar). The corrected profile is reported separately;
  only `ruling: decided` corrected vectors count, `proposed` ones are UNRULED (advisory).
- A component meets its bar when kitrun exits 0 for its areas on the shipped set AND the maintainer's holdout run
  meets the holdout column.

## 2. Grading procedure (maintainers)

1. Receive the implementation (source + adapter command). Build it in a clean environment.
2. Shipped set: `python3 scripts/kitrun.py --impl-cmd "<adapter>" --profile compat --report shipped.json`
   (`--parallel 4` for speed). Corrected: same with `--profile corrected --report corrected.json`.
3. Holdout: add `--include-holdout reimplementation-kit/maintainer-data/holdout --report holdout.json`; the report
   carries separate `holdout` rows. A gap of more than 10 points between shipped and holdout rates flags overfitting.
4. Events-processor: separate runs per profile (§2.1): `events-processor-spec/scripts/run-suite.sh --impl-cmd
   "<consumer>" --mode db --profile corrected` (and `--mode cache` when the implementation supports memory-cache
   mode); for a migration-compat build also `--profile compat --loose-errors --mode db` with the implementation's
   compat setting; `kitrun.py --areas ep` with `--profile compat` and `--profile corrected`.
5. Keep the JSON reports and the gap log; triage every non-PASS (§5).

### 2.1 Events-processor profiles: separate runs

The compat goldens of the events-processor suite reproduce the reference's silent-loss modes and quirks (for
example a commit past an unprocessed record, `<nil>` value text) while the corrected assertions forbid them, so no
single configuration meets both thresholds. Rules:

- Each profile is graded on its own run: the corrected thresholds on `--profile corrected` runs, the compat
  threshold on a `--profile compat --loose-errors` run. A `--profile both` run is not a grading run.
- An implementation that offers both profiles may expose a profile switch of its own, for example an environment
  variable (`--impl-env MY_EP_PROFILE=compat`) or a command-line flag in `--impl-cmd`. The switch is the
  implementation's choice and not part of the environment contract; the same build serves every run and only the
  switch differs. The report names the switch and its value for each run.
- An implementation that offers only one profile is graded on that profile: corrected for a greenfield build (the
  default bar), compat only when a migration-compat build is claimed.
- Under the suite the implementation may also run with its retry delays capped at 2 s (an implementation setting,
  `events-processor-spec` reference/delivery-and-failures.md EP-R3), because the suite ends a wait after 3 s
  without an observable change.

## 3. Reading a report

- Start from the area table: VERDICT FAIL rows first, then CORE below 100 %.
- In `vectors[]`, group FAIL diffs by `op` and by the first diff path: a single wrong rule usually explains many
  vectors.
- `ERROR` with `adapter_error.code = bad_input` means the adapter could not read the input: a schema
  misunderstanding (K-FMT candidate) or an implementation gap.
- `SKIP` rows show unimplemented ops; `skipped_ops` in the summary counts them.
- `warnings` with NUM-OUT mean the adapter returns JSON numbers where decimal strings are expected: harmless for
  integers, risky for decimals (binary float leakage).

## 4. Clean-room acceptance of the kit

The kit is accepted when implementers who never saw the reference source rebuild the components from the kit alone
and meet the thresholds on the shipped set AND the holdout.

### 4.1 Isolation (decided 2026-10-02: pack-only branch)

1. `scripts/maintainer/kit-pack.sh --cleanroom --out-dir <scratch clone>` builds the pack: the three kit skills
   under `.claude/skills/` WITHOUT `scripts/maintainer/`, `maintainer-data/` (holdout), `reference/maintainer-oracle.md`
   and any file carrying the MAINTAINER-ONLY header; it verifies `kit.json` hashes, runs the validator inside the pack
   and refuses the pack if forbidden content remains (repository or cache paths, scratch paths, planning or discovery
   ids, Ruby source, holdout ids).
2. The pack is committed on a pack-only branch (`kit-pack-v1`) from a separate scratch clone, never from the working
   branch, and pushed to the project's origin.
3. Each implementer runs in a fresh remote session that clones only that branch: no umbrella repository history, no
   lago-api checkout, no cache directory. Package egress only (for example PyPI for `cryptography`,
   `confluent-kafka`, `redis`, `psycopg2-binary`).
4. Residual risk (accepted by the owner): a session could still fetch other branches or clone the reference from
   GitHub. Isolation is by construction plus instructions plus the transcript audit of §4.3.

### 4.2 Implementer brief

"Implement <components> in Python 3.12 from the kit only. Do not read anything outside the work directory. Do not
search the web for Lago. Do not embed vector ids or expected values in code; never read `expected` to build lookup
tables. Log every question the kit does not answer in `KIT-GAPS.md` (question, where you looked, your assumption).
Use kitrun.py until the thresholds are met; deliver code and the final kitrun report."

CRC-2, CRC-4 and CRC-6 (the largest spec surfaces) each get two independent implementers.

### 4.3 Audit

- Transcript scan of every implementer session for forbidden paths and URLs (the reference repositories, the cache
  directory, the umbrella repository).
- Code scan for vector ids and long decimal literals copied from vectors.
- Holdout-versus-shipped gap > 10 points flags overfitting.

## 5. Triage of a failing vector

```
non-PASS vector
 ├─ protocol trouble (ERROR bad_input/internal, garbage line, timeout)?
 │    └─ schema or encoding misunderstanding?  yes → K-FMT    no → IMPL
 ├─ does the oracle (reference at the pin) reproduce `expected`?  no → K-VEC
 ├─ is the rule missing, ambiguous, contradicted by another rule/vector,
 │  or only inferable from vectors?                                yes → K-SPEC
 └─ rule clear, implementation deviates                             → IMPL
```

| Class | Meaning | Action |
|---|---|---|
| K-VEC | the vector is wrong (the oracle disagrees) | fix the vector, add a regression note; patch kit version |
| K-FMT | protocol/format misunderstanding (schema ambiguity, unclear compare mode, undeclared default) | fix schema or `vector-format.md`; patch version |
| K-SPEC | the chapter does not let a careful reader derive the expected value | fix the chapter, add the missing vector; minor version |
| IMPL | the rule is clear and the implementation deviates | no kit change |

Tie-break: when both independent implementers fail the same vector with the same wrong value, presume K-SPEC; when
they differ, read both rationales against the cited rule. Every `KIT-GAPS.md` entry is classified the same way (a
gap that caused no failure is still a K-SPEC candidate).

Fix loop: kit fixes are new kit versions (patch for K-VEC/K-FMT, minor for K-SPEC); re-pack; affected components
re-run; re-implementation only when a K-SPEC changed semantics.

## 6. Exit criteria (a kit version is accepted)

- CRC-1..CRC-9 meet their thresholds on shipped AND holdout sets;
- 0 open K-VEC; at most 3 open minor K-SPEC, each with a ticket;
- events-processor corrected profile: 100 % of decided assertions on the corrected run (compat graded on its own
  run, §2.1);
- a report for the owner: pass rates per component, the defect list, a summary of the gap log.

## Provenance (maintainers)

- Thresholds and procedure: kit plan of record (2026-10-02) section 7; isolation option A decided by the owner on
  2026-10-02 (pack-only branch, fresh remote sessions, transcript audit).
- `kit-pack.sh --cleanroom` verified 2026-10-02 on the staging tree: maintainer files stripped, forbidden-content
  scan 0 findings, the in-pack `kit-selftest.sh` runs with the selftest-adapter steps reported SKIP.
- Separate events-processor runs per profile (§2.1): decided by the lead on 2026-10-02 after the clean-room run, where
  one implementation met every corrected threshold and 30/30 compat goldens with a profile switch, but only 13/30
  compat goldens with its single default (corrected) configuration.
- Update triggers: a threshold change (edit `acceptance/thresholds.json` and §1 together), a new component, an owner
  decision on isolation.
