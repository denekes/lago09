# The black-box conformance suite (`run-suite.sh`, runner `epconf`)

Part of `events-processor-spec` (re-implementation kit v1.0.0). Read when you run the suite against an
implementation under test (IUT), read a DIFF or FAIL, add a scenario, or re-mint goldens. The suite drives ANY
implementation through its real interfaces only: Kafka, Redis, Postgres, process signals and exit status. It is
independent of the reference's language and client libraries (proved with a Python IUT on librdkafka).

> **Licence.** The Lago events-processor and lago-api are AGPL-3.0. The suite is kit code written for the kit; it
> neither imports nor copies events-processor source. Scenarios and goldens are behavioural data. A clean-room
> rebuild that will not be AGPL needs legal review (`reimplementation-kit` reference/legal-and-provenance.md).

## 1. Quick start

```bash
S=.claude/skills/events-processor-spec
bash $S/scripts/run-suite.sh --impl-cmd "/path/to/my-processor" --mode db --profile both --loose-errors
bash $S/scripts/run-suite.sh --impl-cmd "/path/to/my-processor" --mode cache --profile both --loose-errors
bash $S/scripts/run-suite.sh --impl-cmd "/path/to/my-processor" --only 'EPC-0[4-7]' --keep /tmp/epc-run
```

Requirements: Go ≥ 1.25 to build the runner once (modules from the Go proxy; binary cached in
`$LAGO_SKILLS_CACHE/epconf-bin/<source sha>/epconf`), `psql` on `PATH`, and a Postgres ≥ 15 role that can
CREATE DATABASE and CREATE ROLE (`--pg-admin URL`, default `$EPCONF_PG_ADMIN_URL`, else
`postgres://lago:lago@localhost:5432/lago`). Kafka and Redis are provided by the runner itself. No Docker.

Output, one line per scenario, then a summary:
```
EPC-04-subscription-matching compat=MATCH corrected=PASS (1.8s)
EPC-20-produce-reject-in-advance compat=MATCH corrected=UNRULED (2.9s)
EPC-31-cdc-charge-update-column-gap SKIPPED (mode db)
run-suite: scenarios=31 failing=0 unruled=1 skipped=4 mode=db profile=both keep=… exit=0
```
`compat=` MATCH | DIFF | NO_GOLDEN | WRITTEN | `-` (not requested or no golden by design); `corrected=` PASS |
FAIL | UNRULED (only assertions with ruling `proposed` failed; advisory) | `-` (no assertion file). Exit 0 = every
requested check passed (UNRULED does not fail), 3 = a DIFF, FAIL or NO_GOLDEN, 2 = setup error. The keep
directory holds per scenario `<name>.observed` (the rendered text), `<name>.out` (diff and assertion lines),
`<name>.stderr` and `<name>.iut-<n>.log` (the IUT's stdout and stderr).

<!-- evidence-check: off normative suite rules; evidence = the scenarios named on each line, run against the Go reference (3 passes per mode) -->

## 2. What the runner owns

- **EP-P1** [vec: EPC-00, EPC-30]
  Isolation per scenario: a fresh in-process Kafka broker (kfake, real Kafka protocol on 127.0.0.1
  TCP), a fresh in-process Redis (miniredis, RESP on TCP), a fresh scratch database `epconf_<pid>` loaded with
  `conformance/fixtures/catalog-base.sql` (dropped afterwards), and a fresh IUT process. The IUT connects to
  Postgres as the cluster role `epconf_iut` (password `epconf`, SELECT only), so per-database connection limits
  apply to it.

Topics seeded: `events-raw` (1 partition unless the scenario says otherwise), `events_enriched`,
`events_charged_in_advance`, `events_dead_letter` (1 partition each); in cache mode also
`epconf_cdc.public.<table>` for the six catalog tables.

Environment handed to the IUT (names are the compat contract, `contract.md` §2; the process also inherits
`PATH`, `HOME`, `LD_LIBRARY_PATH`, `TMPDIR`; extra pairs come from `--impl-env K=V` and from the scenario's `env`,
where `$UNSET` removes a variable):

| Variable | Value |
|---|---|
| `LAGO_KAFKA_BOOTSTRAP_SERVERS` | the runner's broker address |
| `LAGO_KAFKA_RAW_EVENTS_TOPIC` | `events-raw` |
| `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC` | `events_enriched` |
| `LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC` | `events_charged_in_advance` |
| `LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC` | `events_dead_letter` |
| `LAGO_KAFKA_CONSUMER_GROUP` | `epconf` (group `epconf_events-raw`) |
| `LAGO_REDIS_STORE_URL`, `LAGO_REDIS_STORE_DB` | the runner's Redis `host:port`, `0` |
| `DATABASE_URL` | the scratch database as `epconf_iut` |
| `ENV` | `development` |
| `LAGO_USE_MEMORY_CACHE`, `LAGO_DEBEZIUM_TOPIC_PREFIX` | `true`, `epconf_cdc` (cache mode only) |

The IUT is started as `sh -c "exec <impl-cmd>"` in its own process group: `exec` makes signals and the exit
status the IUT's own (a wrapper script must also `exec` its final command).

## 3. Lifecycle of one scenario

1. Load the fixture and scenario SQL; wrap the scenario's `db_fault_tables` (§4); grant `epconf_iut`; apply a
   `db_connection_limit` if set.
2. Start broker and Redis, start the IUT.
- **EP-P2** [vec: EPC-26, EPC-27, EPC-28, EPC-29]
  Readiness: wait until the group `epconf_events-raw` is Stable and its members own every raw
  partition (timeout 60 s; 30 s for startup-contract scenarios). If the IUT exits first, record
  `exit_before_ready=<status>` and skip the steps.
3. Execute the steps (§5).
- **EP-P3** [vec: EPC-10, EPC-14, EPC-17]
  Quiescence (`{"wait": "quiescent"}`): poll every 100 ms the tuple (end offsets of the raw and output
  topics, committed offsets of the group, refresh-set size). Quiescent = unchanged for `settle_ms` (default
  1000) with every raw record committed, or unchanged for `withheld_settle_ms` (default 3000) with some records
  uncommitted. Timeout 60 s (a step failure noted in the output). The suite never sleeps a fixed time to wait
  for an IUT.
4. Stop: SIGTERM, wait up to 30 s (then SIGKILL, reported), record the exit status.
5. Collect every observable output and render the canonical text (§6); compare with the golden (compat) and/or
   evaluate the assertion file (corrected).

## 4. Fault injection

- **EP-P4** Faults are injected at the edges only, never inside the IUT. [vec: EPC-10, EPC-15, EPC-16, EPC-17, EPC-18, EPC-19, EPC-20, EPC-21, EPC-30]

| Fault | Mechanism | Step |
|---|---|---|
| transient Postgres error on a table | the table is renamed and replaced by a view whose filter calls a SECURITY DEFINER gate ONCE per query (uncorrelated scalar sub-select); the gate draws from a sequence (non-transactional) and raises SQLSTATE 58030 inside an armed window of N calls; "fired" = the sequence passed the window start | `db_fault {table, times}`, `wait_db_fault_fired` |
| Redis error | the in-process Redis answers every command with an error | `redis_error "<text>"`, `""` clears |
| broker rejects a produce | produce requests for the listed topics are answered with INVALID_RECORD | `kafka_reject_produce [topics]`, `[]` clears |
| restart | SIGTERM (or SIGKILL) then a new IUT process and readiness | `restart "TERM"` / `"KILL"` |
| connection limit | `ALTER DATABASE … CONNECTION LIMIT n` for the IUT role | scenario `db_connection_limit` |
| catalog change (cache mode) | a flat CDC row produced to `epconf_cdc.public.<table>` (`$NOW_US` = now in µs); applied = some non-raw group committed the CDC topic to its end | `cdc {table,row}`, `wait_cdc_applied` |

Neighbour records that must be processed AFTER a fault are produced only after the gate reported "fired" and the
IUT is quiescent; otherwise the faulted record may be processed after the window and the scenario tests nothing.

## 5. Scenario file format (`conformance/scenarios/EPC-NN-<slug>.json`)

| Key | Meaning |
|---|---|
| `name`, `id`, `description`, `rules`, `rbd` | identity and metadata (`rules` = EP rule ids pinned, `rbd` = rebuild decisions exercised) |
| `catalog` | SQL files loaded first (relative to the scenario file), normally `../fixtures/catalog-base.sql` |
| `sql` | extra SQL after the catalog |
| `db_fault_tables` | tables wrapped for fault injection before the IUT starts |
| `partitions` | raw-topic partitions (default 1) |
| `env` | IUT environment overrides (`""` sets empty, `$UNSET` removes) |
| `defaults` | fields merged into every JSON record unless present (`organization_id`, `external_subscription_id`, `ingested_at`, `properties`) |
| `modes` | modes the scenario applies to (default both) |
| `expect_no_ready` | startup-contract scenario: the IUT must exit before readiness |
| `db_connection_limit`, `no_golden`, `settle_ms`, `withheld_settle_ms` | see above (`no_golden` = timing-dependent, assertions only) |
| `steps` | ordered list (one action per step) |

Steps: `{"produce": [records]}`, `{"wait": "quiescent"}`, `db_fault`, `wait_db_fault_fired`, `redis_error`,
`kafka_reject_produce`, `restart`, `sql` (run against the scratch database), `cdc`, `wait_cdc_applied`, `note`,
`sleep_ms` (not used by the catalogue). A record is `{"json": {...}}` (merged with `defaults`; a string value
`$ABSENT` removes the key; templates `$INGESTED_NOW`, `$INGESTED_11H_AGO`, `$INGESTED_13H_AGO`
(`YYYY-MM-DDTHH:MM:SS.fff` UTC relative to the run) and `$EPOCH_NOW`) or `{"raw": "<exact bytes>"}`, with optional
`key`, `partition`, `label` (ledger label when there is no `transaction_id`), `no_defaults`. Number literals in
scenario files are kept verbatim on the wire (`1e21` stays `1e21`): never re-format scenario files with a JSON
library that rewrites numbers; regenerate them with `scripts/gen-scenarios.py`.

## 6. Observed text and golden grammar

- **EP-P5** [vec: EPC-00, EPC-09, EPC-24]
  Canonical rendering per `wire-formats.md` EP-W7 (sorted keys, literal numbers, masks for `failed_at`,
  templated `ingested_at` and the refresh bucket). Keys are rendered quoted or `<none>`.
- **EP-P6** [vec: EPC-09, EPC-25, EPC-30]
  Ledger: every produced raw record gets one class: `ENRICHED` (≥ 1 enriched record),
  `DLQ` (≥ 1 dead-letter record, no enriched), `ENRICHED+DLQ`, `NO_OUTPUT_COMMITTED` (committed with no output:
  silent loss), `PENDING_UNCOMMITTED`. Outputs are attributed by `transaction_id` (dead-letter: `event.transaction_id`),
  or for a dead-letter record carrying `raw_event` by byte equality with a produced raw value; anything else is
  listed as unattributed.

```
# epconf golden v1 scenario=<name> mode=<db|cache>
[ledger] label partition:offset class enriched/in_advance/dlq committed
<label> p<P>:o<O> <CLASS> e=<n> a=<n> d=<n>[ codes="<code>",…] committed=<true|false>
[unattributed outputs] <n>
<topic> tx="<transaction_id>"
[topic events_enriched] <n> record(s)
key=<"key"|<none>> <canonical JSON>          (sorted by key, then canonical text)
[topic events_charged_in_advance] <n> record(s)
[topic events_dead_letter] <n> record(s)
[commits] group=epconf_events-raw
p<P> end=<end offset> committed=<offset|none>
[redis subscription_refreshed_v2] <n> distinct masked member(s), <n> invalid
<organization>:<subscription>|<BUCKET>
[process]
exit_after_sigterm=<status> | exit_before_ready=<status> | exit_before_sigterm=<status>
starts=<n>
group_present=<bool> other_groups=<n|->      (other_groups = CDC groups etc.; "-" after a startup failure)
```
Comparison is a multiset of lines (order-free; blank lines and lines starting with `##` ignored).
`--loose-errors` masks `initial_error_message` to `<TEXT>` (empty stays empty) and a non-zero
`exit_before_ready` status to `NONZERO`: use it for any IUT that is not the reference binary.

## 7. Profiles and assertions

- **EP-P7** [vec: EPC-04, EPC-07, EPC-20, EPC-31]
  `compat` = golden text equality per mode (`conformance/golden/compat-db/`, `compat-cache/`).
  `corrected` = assertion files `conformance/golden/corrected/<scenario>.assert.json` (same file for both modes),
  each assertion carrying `kind`, optional `tx`/`want`/`any_of`, `why`, `rbd` (non-empty) and `ruling`
  (`decided` → graded; `proposed` → reported as UNRULED, never fails the run).

| Kind | Passes when |
|---|---|
| `all_done` | every raw record is ENRICHED or DLQ (nothing pending, nothing silently committed, no mixed outcome) |
| `all_accounted` | no record is NO_OUTPUT_COMMITTED (weaker: pending allowed; avoid) |
| `no_dup` | no record has more than one enriched or more than one in-advance record |
| `value` | the first enriched record of `tx` has `value` = `want` (or one of `any_of`) |
| `subscription` | the first enriched record of `tx` has `subscription_id` = `want` (`""` = none) |
| `enriched` / `in_advance` | `tx` has at least one enriched / in-advance record |
| `not_in_advance` / `not_on_dlq` | `tx` has none |
| `on_dlq` | `tx` has a dead-letter record with a non-empty `error_code` |
| `done_with_cause` | `tx` is enriched, or dead-lettered with a non-empty `error_code` |
| `zset_has` / `zset_lacks` | a masked refresh member starting with `want|` exists / does not exist |
| `startup_exit` | the IUT exited with a non-zero status before readiness |

<!-- evidence-check: on -->

## 8. Reference results (2026-10-02, runner and goldens of this kit version)

| IUT | Mode | compat | corrected FAIL (decided) | corrected UNRULED |
|---|---|---|---|---|
| Go reference (tree 83e0128), 3 full passes | db | 30/30 MATCH | EPC-04, 07, 08, 09, 10, 14, 15, 16, 17, 18, 19, 30 | EPC-20 |
| Go reference, 3 full passes | cache | 27/27 MATCH | EPC-04, 07, 08, 09, 17, 18, 19 | EPC-20, EPC-31 |
| Python self-test IUT (corrected design, librdkafka) | db, `--loose-errors` | 9/30 MATCH (expected: it implements the corrected profile) | EPC-18 (documented deviation: retries a broker rejection instead of dead-lettering) | — |

Measured on the way: a 201-record burst against a 30-connection limit lost 85 to 170 records in nine runs (EPC-30,
reference binary); the strings `NaN` and `Inf` as `timestamp` are silently lost (EPC-08); in cache mode an
external id that is a `:`-prefix of another one sees both subscriptions (unit vectors, EP-H8).

## 9. Grading a new implementation (component CRC-9 of `reimplementation-kit`)

| Check | Command | Threshold |
|---|---|---|
| corrected profile, decided assertions | `run-suite.sh --profile corrected --mode db` and `--mode cache` | 100 % PASS |
| compat, portable | `run-suite.sh --profile compat --loose-errors --mode db` | ≥ 90 % of DB goldens MATCH (only for a migration-compat build) |
| startup contract | EPC-26..29 corrected | 4/4 |
| unit vectors | `kitrun.py --areas ep --impl-cmd …` (`reimplementation-kit`) | ≥ 95 % shipped, 100 % core |

## 10. Gotchas for implementers (each one cost a debugging session)

1. librdkafka-based producers: the in-process broker rejects record batches whose partition-leader-epoch field
   is not −1; the runner rewrites that field (outside the CRC) on every produce, so no IUT change is needed. If you
   swap in another broker, expect CORRUPT_MESSAGE from librdkafka ≤ 2.15 against older broker emulators.
2. Start your process with `exec` in any wrapper; otherwise SIGTERM hits the shell and the exit status becomes a
   signal.
3. Retry only the failed side effect. Re-producing the enriched record on every retry never becomes quiescent and
   fails `no_dup` (EPC-17).
4. Keep number literals: decode `properties` with a literal-preserving JSON reader if you target the corrected
   value rules; a JSON library that turns `1e21` into a float has already lost the corrected `value`.
5. `ingested_at` in scenarios is relative to the run; the golden keeps its layout (`<NOW-11h:…>`), not the value.
6. An empty broker list must make the process exit non-zero quickly; some client libraries wait forever (EPC-29).
7. Connection pools: the reference's default of 200 exceeds many databases' limits (EPC-30); scenarios with many
   records set `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` (EPC-21: 20).
8. Superusers ignore per-database connection limits; that is why the IUT gets its own role.
9. In cache mode the CDC topics must exist before the IUT starts (the runner seeds them).
10. The suite does not observe a retry topic (KQ-1): make in-place retries succeed for one-shot faults.

## 11. Adding or changing a scenario (maintainers)

1. Edit `scripts/gen-scenarios.py` (never hand-edit generated files), run `gen-scenarios.py --write`, and
   check that `gen-scenarios.py` (default `--check`) reports no drift.
2. Mint the compat goldens from the Go reference with a reviewed diff:
   `scripts/maintainer/regen-goldens.sh --only 'EPC-NN' --passes 3` (every pass must agree), then `--apply`.
3. Assertions must cite an RBD and a ruling; a new failure class needs a new assertion kind in the runner.
4. Re-run both modes in full three times and update §8.

## Provenance (maintainers)

Runner source `scripts/runner/main.go` (kit code; dependencies: kfake pseudo-version
`v0.0.0-20251123185109-2b5c574e9ddd`, franz-go v1.20.5, kadm v1.17.1, miniredis v2.37.0). Reference binary built
from events-processor tree `83e012866f29` by `scripts/maintainer/build-go-reference.sh`. Results in §8: three full
passes per mode with `run-suite.sh --profile both` on 2026-10-02 (Postgres 16, `max_connections=100` shared with
other workloads); self-test IUT `scripts/maintainer/selftest-iut.py` with confluent-kafka (librdkafka 2.15.1),
redis-py 8.1.0, psycopg2 2.9.13. Broker leader-epoch behaviour: kfake source at the pseudo-version above, produce
handler (record-batch validation).

EPC-04 offset case changed on 2026-10-02: `sm_ts_offset` now carries `2025-02-28T23:30:00-01:00` (the instant 00:30Z
on 1 March), so its corrected expectation is the open subscription …004, which every cache snapshot holds; the earlier
expectation …003 (terminated 2025-03-01) lies outside the cache-mode window (EP-H7) and could not pass in cache mode
whatever the offset rule. Compat goldens of both modes re-minted with `scripts/maintainer/regen-goldens.sh --only
EPC-04 --passes 3` (the three passes agreed; only the `sm_ts_offset` record changed: DB …003 by wall clock, cache …004
as an instant). One full pass per mode afterwards (`run-suite.sh --profile both`) reproduced §8: DB 30/30 and cache
27/27 compat MATCH, the same corrected FAIL and UNRULED sets; EPC-04 now fails four decided assertions in DB mode
(RBD-15 three times, RBD-16) and three in cache mode (RBD-15 twice, RBD-17).
