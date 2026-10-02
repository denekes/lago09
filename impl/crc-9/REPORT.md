# REPORT — crc-9 events-processor (Python 3.12, DB mode)

Run from the repository root on 2026-10-02 (Postgres 16.14, librdkafka 2.15.1 via confluent-kafka 2.15.1,
redis-py 8.1.0, psycopg2 2.9.13, runner built with `GOTOOLCHAIN=auto`).

## Thresholds

| Threshold | Result |
|---|---|
| corrected profile, 100 % of decided assertions (DB) | **met**: 3 consecutive `--profile corrected` runs, `failing=0 unruled=0` (EPC-20, proposed, also passes) |
| startup contract EPC-26..29 | **met**: 4/4 (corrected PASS; compat MATCH) |
| ep unit vectors ≥ 95 % | **met**: compat 116/116, corrected 105/105 decided (+4 UNRULED twins that also pass) |
| compat ≥ 90 % of DB goldens | **not met by the single default command** (13/30 = 43 %, the corrected default cannot reproduce reference loss modes); **met by the same code with `EP_PROFILE=compat`**: 30/30 (see KIT-GAPS 1) |

## run-suite, the specified command (`--mode db --profile both --loose-errors`, default = corrected)

Summary line: `run-suite: scenarios=31 failing=17 unruled=0 skipped=4 mode=db profile=both exit=3`
(all 17 "failing" are compat DIFFs; there is no corrected FAIL).

Per scenario (compat / corrected):

```
EPC-00 DIFF/-     EPC-01 DIFF/-     EPC-02 MATCH/-    EPC-03 MATCH/-    EPC-04 DIFF/PASS  EPC-05 MATCH/-
EPC-06 DIFF/-     EPC-07 DIFF/PASS  EPC-08 DIFF/PASS  EPC-09 DIFF/PASS  EPC-10 DIFF/PASS  EPC-11 MATCH/PASS
EPC-12 DIFF/PASS  EPC-13 DIFF/PASS  EPC-14 DIFF/PASS  EPC-15 DIFF/PASS  EPC-16 DIFF/PASS  EPC-17 DIFF/PASS
EPC-18 DIFF/PASS  EPC-19 DIFF/PASS  EPC-20 DIFF/PASS  EPC-21 MATCH/PASS EPC-22 MATCH/-    EPC-23 MATCH/-
EPC-24 MATCH/-    EPC-25 MATCH/-    EPC-26 MATCH/PASS EPC-27 MATCH/PASS EPC-28 MATCH/PASS EPC-29 MATCH/PASS
EPC-30 -/PASS     EPC-31..34 SKIPPED (cache mode only)
```

The compat DIFFs are the intended differences of the corrected profile (value text, binary64 re-encoding,
no silent loss, dead letters for undecodable records, retries instead of loss).

## run-suite compat of the same code (`--impl-env EP_PROFILE=compat --profile compat --loose-errors`)

`run-suite: scenarios=31 failing=0 unruled=0 skipped=4 mode=db profile=compat exit=0` — EPC-00..29 all MATCH
(30/30; EPC-30 has no golden).

## kitrun

`python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "impl/crc-9/.venv/bin/python impl/crc-9/adapter.py" --areas ep --profile compat`

`SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=116 passed=116 skipped_ops=0 exit=0`
(`--profile corrected`: `vectors=109 passed=105`, 4 UNRULED twins pass, exit 0).

## Time spent

About 1 h 10 min of wall clock (reading the kit ~15 min, core + expressions ~20 min, processor and suite debugging
~25 min, adapter, compat switch and write-up ~10 min). Commits: progress after the corrected suite passed, final
at the end.

## What I would do next

1. Cache mode (CDC consumers, snapshot, EP-N rules) — out of scope here.
2. A real retry topic (KQ-1) so one poisoned/blocked record does not stall its partition (today: head-of-line
   blocking with backoff, in-place retries only).
3. Re-enable the idempotent producer once the broker emulator copes with it, or add an application-level
   duplicate guard; parallelise records of different partitions (one worker per partition) and batch produces.
4. Honour pause()/resume() with the fetched-record purge semantics instead of blocking, plus metrics (disposition
   counters, lag, retry depth) from ADR-001.
5. Unit tests for `expr.py` against the `expression.*` vectors (an `expression.evaluate` adapter op, mode `ep`).
