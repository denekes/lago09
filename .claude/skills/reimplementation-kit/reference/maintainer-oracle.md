<!-- MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs. -->
# The executable oracle (maintainers)

> Licence note: the oracle runs lago-api (AGPL-3.0) at pin `591ae90` locally to observe its behaviour; nothing from
> it is copied into kit text. This document and `scripts/maintainer/` are never part of a clean-room pack.

The oracle answers the kit's adapter protocol with lago-api code at the pin, so kit vectors can be EXECUTED (not
merely read from specs) and re-minted after a pin bump. It also runs the reference's own rspec suite without
Docker. Everything lives in `scripts/maintainer/`: `oracle.sh` (toolchain and runs), `oracle-adapter/oracle_adapter.rb`
(protocol loop) and `oracle-adapter/ops/<area>.rb` (one module per area, written by the area's author).

## 1. Environment

| Need | Version used | Why |
|---|---|---|
| Pinned lago-api checkout | `591ae9005110` via `research-methodology/scripts/pinned-checkout.sh api` | source of truth, read-only |
| Writable copy | `$LAGO_SKILLS_CACHE/lago-api-run@591ae90` | `vendor/bundle`, `config/keys`, logs |
| Ruby 4.0.6 + Bundler 4.0.16 | conda-forge build (`$LAGO_SKILLS_CACHE/rubies/ruby-4.0.6-conda`) | the lockfile's versions; the Ruby source tarball host is not reachable from the sandbox |
| Rust toolchain + libclang with resource headers | system LLVM 18 | the expression engine gem compiles a Rust extension |
| PostgreSQL ≥ 15 (16 used) | role `lago`/`lago` | test database per person (`ORACLE_DB`) |
| Redis | 7.0.15, port 6391 (shared) | cache/queue endpoints the app expects |
| ClickHouse (optional) | 26.2 local server on :8123 | ClickHouse-store specs and vectors only |

## 2. Commands (observed 2026-10-02)

| Command | Result |
|---|---|
| `LAGO_SKILLS_CACHE=<empty dir> ORACLE_API_RO=<pinned checkout> ORACLE_DB=<db> oracle.sh setup` | from zero: conda env + copy + `bundle install` (Rust included) + schema load in **94 s**; footprint 2.2 GB; rerun 1 s (`setup done in 1s`) |
| `oracle.sh run spec/services/charge_models` | `{"example_count":140,"failure_count":0,"pending_count":0,"errors_outside_of_examples_count":0,…}` in 21 s |
| `ORACLE_DB=lago_api_test_a1 oracle.sh db` | creates the database from `structure.sql` minus the pg_partman line in 3.5 s |
| `oracle.sh db --reset` | drops and recreates `$ORACLE_DB` even when its migration count is current (rows left behind by non-transactional specs or probes) |
| `oracle.sh adapter` (as `kitrun.py --impl-cmd`) | boots in about 3 s; `hello` lists the registered ops; `kitrun.py --vectors selftest/domain.selftest.jsonl` → 23/23 PASS |
| `oracle.sh status` | ruby, copy, gems, redis, database migrations (1121 expected), clickhouse, op modules |
| `oracle.sh clickhouse` | starts the local server (under `ch.lock`) and runs the ClickHouse migrations |
| `oracle.sh run -j N [-r FILE] <paths>` | rspec over N databases (`$ORACLE_DB`, `${ORACLE_DB}_2..N`); `-r` loads a recorder |
| `oracle.sh run spec/services/utils/datetime_spec.rb:214 spec/services/utils/datetime_spec.rb:223 'spec/models/concerns/billing_period_date_diff_spec.rb[1:1]'` | single examples by rspec location (`file:line`, `file:line:line`, `file[ids]`): `{"example_count":5,"failure_count":0,…}` in 12 s (2026-10-02) |
| `eval "$(oracle.sh env)"` | the exports used for rspec/adapter (mirrors the reference CI env block) |

## 3. Hygiene when several people (or agents) share one machine

1. **One database per person**: `ORACLE_DB=lago_api_test_<you>`. The reference suite deletes every row of its
   database before it starts; never point two runs at the same database. `oracle.sh db` creates it.
2. **Small parallelism**: PostgreSQL `max_connections` is 100 and shared; use `-j 1` (at most `-j 2`).
   "too many clients already" is transient: rerun.
3. **ClickHouse**: ClickHouse-tagged suites wipe ClickHouse tables; `oracle.sh` serialises them through
   `flock $LAGO_SKILLS_CACHE/k7-state/ch.lock`. Untagged spec files that use the ClickHouse events store
   (`clickhouse_events_store` contexts, which write rows) also run in job 1 under that lock when ClickHouse is up.
   Take the same lock for any manual ClickHouse work. Op modules that touch ClickHouse take the lock per call (with a
   bounded wait), so never wrap `kitrun.py` itself in `flock …/ch.lock`: the adapter would wait for its own runner.
4. **Gems**: never run `bundle install` concurrently in the shared copy; `oracle.sh setup` holds
   `$LAGO_SKILLS_CACHE/k7-state/bundle.lock`.
5. **Clocks**: the adapter travels back after every call; in rspec, frozen clocks can leak between examples — rerun a
   suspicious failure alone.
6. **Scenario replays truncate**: the stateful `system.reset` op erases every row of the oracle database (it refuses
   databases not named `lago_api_test*`). Replay scenarios only against a database of your own.
7. If PostgreSQL is down: `pg_ctlcluster 16 main start`. Never stop the shared Redis or ClickHouse (`oracle.sh stop`
   is for the person who started them).

## 4. Writing an op module (`oracle-adapter/ops/<area>.rb`)

```ruby
# MAINTAINER-ONLY header line …
KitOracle.op("domain.days_between") do |input, ctx|
  from = ctx.instant(input.fetch("from"))          # Time in UTC from an instant string
  days = <call the real lago-api code path here>
  {"days" => days}                                  # Hash = output; values are normalised for you
end
```

Context helpers (`ctx`):

| Helper | Use |
|---|---|
| `ctx.dec(x)` / `ctx.dec_out(d)` | exact decimal from a string/number; canonical decimal text |
| `ctx.instant(s)` / `ctx.instant_out(t)` | parse an instant / print UTC `…Z` with trailing zeros trimmed |
| `ctx.input_decimal` | the request re-parsed with every JSON number as an exact decimal (payload literals) |
| `ctx.line` | the raw request line (for `*_json` literal work) |
| `ctx.rollback { … }` | run in a transaction on the primary and events connections that is always rolled back (use FactoryBot inside); after-commit callbacks (jobs, webhooks) never fire inside it |
| `ctx.travel(at) { … }` | freeze the clock at an instant (every record created in the block shares `created_at`) |
| `ctx.premium(true) { … }` | enable the premium licence flag for the block |
| `ctx.domain_error!(code, field)` | answer a domain error (graded against `expected.error`) |
| `ctx.bad_input!(msg)` | answer `bad_input` (the input does not fit the op schema) |

Rules: call the real code path the reference uses (service objects, model methods, query classes), not a re-typed
formula — otherwise the vector is RECOMPUTED, not EXECUTED; never print to stdout (the adapter has redirected it, but
keep logs on stderr); one module per area, registered ops override the built-ins (`domain.days_between`,
`domain.round`); outputs are normalised (BigDecimal → canonical string, Time → UTC instant, Date → `YYYY-MM-DD`,
Float → shortest decimal string).

Patterns the area modules use (copy them rather than inventing new ones):

- **Observing after-commit effects** (jobs enqueued, webhooks): run the op inside a transaction that is not joinable
  and is rolled back at the end, the way the reference's transactional specs work, instead of `ctx.rollback`; the
  periods and alerts modules do this (alerts defines a shared helper that the progressive and wallet modules reuse, so
  module file names fix the load order).
- **Code that reads through another database role** (the reference's `direct` role): point that role at the writing
  pool for the duration of the call and restore it afterwards.
- **Payload numbers**: the generic normalisation turns non-integer numbers into decimal strings, which loses the
  number/string distinction inside payloads; emit payload numbers as raw JSON fragments with their exact text (the
  events module does this).
- **A process-killing input** (a division by zero in an expression aborts the engine): evaluate such inputs in a
  subprocess first and answer the protocol error `internal` instead of letting the oracle die.

## 5. Minting and checking vectors

1. Pick a reference example (spec file:line) or construct an input for a rule.
2. Write the vector with `input` and your best `expected`; run
   `ORACLE_DB=<db> python3 scripts/kitrun.py --impl-cmd "scripts/maintainer/oracle.sh adapter" --vectors <file>`.
3. PASS → evidence `{"kind":"EXECUTED","by":"oracle-adapter","ref":"<spec or code line>","pin":"591ae9005110",
   "runtime":"ruby-4.0.6 (pinned)","executed_at":"<date>"}`. FAIL → the oracle is right: correct `expected`, re-run,
   and tell the area owner if it contradicts a chapter rule.
4. When the oracle cannot run an op (missing module, external dependency), a vector may be EXECUTED `by: spec-green`
   if a reference example asserting exactly these values ran green: `oracle.sh run spec/…_spec.rb:<line>` runs just
   that example (section 2). Otherwise RECOMPUTED with a note.
5. Before hand-off: `validate-vectors.py <files>` (0 errors), `vector-provenance.py <files>` (0 broken refs), kitrun
   vs oracle 100 % of `both`/`compat` vectors in your areas.

Runner self-checks: `kitrun.py --impl-cmd "python3 scripts/maintainer/selftest-adapter.py"` must give 100 % PASS
on every profile and, with `--mutate`, ≥ 99 % FAIL (`kit-selftest.sh` does both).

At integration (in this order, after every content edit): `scripts/maintainer/holdout-split.py --check`, then
`--write` (seeded 20 % sample into `maintainer-data/holdout/`; `vector-format.md` section 10), `validate-vectors.py
--gate --rule-coverage`, then `scripts/maintainer/make-kit-json.py --write` (sha256 manifest) and `kit-pack.sh`.

## 6. Re-minting on a pin bump

1. Check out the new pin (`pinned-checkout.sh api <sha>`), make a new writable copy, `oracle.sh setup` with
   `ORACLE_API_RO`/`ORACLE_APP` pointing at them.
2. Update `PIN` in `oracle.sh` and the `pin` values (`kitlib.BILLING_PIN`, vectors) together.
3. Run kitrun vs the oracle over all `both`/`compat` vectors and `vector-provenance.py`.
4. Triage each FAIL: behaviour change upstream (update vector + chapter rule + Provenance, note it in the release
   notes of the kit) or kit defect (fix). Broken `evidence.ref` lines are re-pointed.
5. Re-run the scenario replay and the events-processor goldens if their sources moved.
6. Bump `kit_version` (minor for behaviour changes) and rebuild the pack.

## 7. Gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (22) … 403` while building Ruby 4.0.6 | the Ruby source host is refused by the egress proxy | conda-forge Ruby (what `oracle.sh setup` does) |
| Bundler cannot reach rubygems through the proxy | Bundler reads `HTTP_PROXY`, not `HTTPS_PROXY` | `oracle.sh` sets `HTTP_PROXY` for `bundle install` only |
| `E0432 unresolved import rb_sys::…` building the expression gem | libclang without resource headers | `LIBCLANG_PATH=/usr/lib/llvm-18/lib` (default in `oracle.sh`) |
| `Errno::ECONNREFUSED … :8123` and "0 examples, 1 error occurred outside of examples" | a ClickHouse-tagged spec file was loaded without a ClickHouse server | `oracle.sh clickhouse`, or let `oracle.sh run` drop those files |
| `could not open extension control file … pg_partman` | the schema creates an extension that is not installed | `oracle.sh` loads the schema without that line |
| `PG::ConnectionBad … too many clients already` | shared `max_connections` 100 | rerun; keep `-j` small |
| `rails db:migrate:clickhouse` fails on `require "annotate_rb"` | dev-only gem not installed | `ANNOTATERB_SKIP_ON_DB_TASKS=1` (in `oracle.sh env`) |
| `Encoding::InvalidByteSequenceError "\xE2" on US-ASCII` | `LANG`/`LC_ALL` unset | `oracle.sh env` exports `C.UTF-8` |
| kitrun SETUP-ERROR with the oracle | database missing or stale | `ORACLE_DB=<db> oracle.sh db` |
| every new adapter process fails its first organization create with `Slug value_already_exist` | rows survived in the database (a direct `rspec` run of examples with `transaction: false`, or a probe outside `ctx.rollback`); the factory sequence restarts at 1 | `oracle.sh db --reset` |
| adapter exit takes about 50 s after an audit-logged endpoint ran | `oracle.sh env` exports the Kafka activity/API log topics, so the endpoint starts a real producer that waits for a broker | remove `LAGO_KAFKA_API_LOGS_TOPIC` and `LAGO_KAFKA_ACTIVITY_LOGS_TOPIC` from the environment for the duration of the request (the events module does) |
| an order-by-creation result flips between runs (about one in three) | records created under one `ctx.travel` share `created_at` | order by the sequential id (or another strict key), never by `created_at` alone |
| identical ClickHouse inserts made close together collapse; `INSERT … VALUES` through `execute` fails | the ClickHouse adapter appends a FORMAT clause and inserts asynchronously | insert one row per statement with `INSERT … SELECT … FROM format(JSONEachRow, …)`, as the aggregation module does |
| `oracle.sh run spec/x_spec.rb:42` printed `no runnable spec files` | an older `oracle.sh` passed the location to `find` | current `oracle.sh` strips the location for discovery and keeps it for rspec |

Known non-environmental failures at the pin (pass when rerun alone): equal-timestamp running totals in
`spec/services/billable_metrics/aggregations/sum_service_spec.rb` (three examples), two prorated-aggregation examples,
and with `run -j 3 spec/scenarios` three order-dependent scenario examples. Vectors must never depend on these orders
(`vector-format.md`, tag `order-dependent`).

## Provenance (maintainers)

- Recipe ported from the oracle feasibility run of 2026-10-02 (8,773 reference examples executed in this sandbox);
  CI env mirrored from `$API/.github/workflows/spec.yml:38-63` @591ae90; test database roles from
  `$API/config/database.yml:59-87`; licence gate skipped in tests per `$API/config/initializers/license.rb:7`;
  premium flag toggled like `$API/spec/support/license_helper.rb:4-8`.
- Built-in ops call `$API/app/services/utils/datetime.rb:55`, `$API/app/models/concerns/billing_period_date_diff.rb:6`
  and `$API/app/services/billable_metrics/aggregations/apply_rounding_service.rb:18`.
- Observations of 2026-10-02 (section 2): from-zero setup 94 s, 2.2 GB; charge-model suite 140/140 in 21 s; adapter
  boot about 3 s; self-test vectors 23/23 PASS; three rspec locations (`file:line` twice, `file[1:1]`) 5/5 examples in
  12 s on a dedicated database.
- Section 7 gotchas and the section 4 patterns come from the area authors' oracle modules of 2026-10-02.
- Update triggers: a pin bump (section 6), a toolchain change (Ruby, Bundler, PostgreSQL, ClickHouse), a new
  gotcha.
