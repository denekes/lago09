# Adapter protocol v1 and the runners

> Licence note: this chapter specifies the kit's own test protocol. The behaviour it grades is that of lago-api
> (AGPL-3.0) at pin `591ae90` and of the Lago events-processor at tree `83e012866f29`; see
> `legal-and-provenance.md`.

An implementation proves conformance by answering the kit's vectors through a small **adapter**: a program that
reads one JSON request per line on stdin and writes one JSON response per line on stdout. The adapter is the only
thing an implementation must add for grading; it can wrap a library call, an RPC client or an HTTP client. The
runner is `scripts/kitrun.py` (standard-library Python ≥ 3.10). Machine-readable message schemas:
`schemas/adapter-protocol.schema.json`.

<!-- evidence-check: off normative spec; evidence = scripts/selftest/test_runner.py (every runner-side rule below has a test; AP-6 is an adapter obligation the runner cannot observe) and the transcripts in section 9 -->

## 1. Transport and lifecycle

| Rule | Statement |
|---|---|
| AP-1 | The runner starts the adapter as `sh -c "exec <impl-cmd>"` in a new process group (so a timeout or crash can kill the whole group). `exec` matters: without it signals reach the shell, not the adapter. |
| AP-2 | Requests are single-line JSON objects (UTF-8, terminated by `\n`) on the adapter's stdin. The adapter writes exactly one single-line JSON response per request on stdout and flushes it. |
| AP-3 | **Nothing else may be written to stdout** — no banners, no logs, no prompts. Logs go to stderr; the runner keeps the last 4 KB of stderr per process and attaches its last 1,500 characters to ERROR/TIMEOUT records in the report (`stderr_tail`). |
| AP-4 | One request is in flight per process (synchronous). `--parallel N` starts N adapter processes and shards vectors across them; adapters must therefore not share mutable state through files. |
| AP-5 | Lifecycle: `hello` → any number of `call` → `bye`. After `bye` (or stdin EOF) the adapter exits with status 0. |
| AP-6 | Calls are independent: an adapter must not carry state from one call to the next (the stateful `system.*` ops of the scenario tier are the only exception). |

## 2. Messages

```jsonc
// runner -> adapter (first line)
{"type":"hello","role":"runner","proto":1,"kit_version":"1.2.0","kit_schema":1,"profiles":["compat"],"areas":["domain","pricing"]}
// adapter -> runner
{"type":"hello","proto":1,"impl":"acme-billing","impl_version":"0.4.2","profiles":["compat","corrected"],
 "ops":["pricing.charge_model","pricing.pay_in_advance","domain.*"]}
// runner -> adapter (one per vector)
{"type":"call","id":"pricing.graduated.011#1","area":"pricing","op":"charge_model","profile":"compat","input":{…verbatim…}}
// adapter -> runner: an output …
{"type":"result","id":"pricing.graduated.011#1","output":{"amount":"163","unit_amount":"7.7619047619047619","amount_details":{…}}}
// … or an error
{"type":"result","id":"pricing.validation.004#1","error":{"code":"invalid_amount","field":"amount","message":"free text"}}
// runner -> adapter (last line)
{"type":"bye"}
```

| Field | Rule |
|---|---|
| `hello.proto` | Must equal the runner's protocol version (1). A mismatch aborts the run (exit 2). |
| `hello.profiles` | The profiles the implementation can answer. If the run's profile is not listed, the run aborts (exit 2). An implementation that only reproduces the reference declares `["compat"]`. |
| `hello.ops` | Ops the adapter answers: exact names (`pricing.charge_model`), an area wildcard (`domain.*`) or `*`. Vectors of other ops are reported SKIP without being sent. |
| `call.id` | `<vector id>#<attempt>` (attempt is 1 in protocol v1). The result must echo it exactly; a different id is a protocol error for that vector (ERROR) and the adapter is restarted. |
| `call.profile` | The run's profile (`compat` or `corrected`). An adapter supporting both must switch behaviour on it. |
| `call.input` | The vector's `input`, forwarded **byte-for-byte** from the vector file: number spellings such as `1e3`, `2.0` or `9007199254740993` reach the adapter unchanged. Parse numbers as exact decimals (never binary floats) unless the rule under test is itself a float rule. |
| `result.output` | An object (the op output). Decimals are strings in canonical form; integers are JSON integers; instants are ISO-8601 with a zone (UTC `Z` recommended). Extra keys are ignored unless the vector is `strict`. A JSON number where a decimal string is expected is accepted; a non-integer one raises warning NUM-OUT (binary-float leakage risk). |
| `result.error` | `{code, field?, message?}`; exactly one of `output` and `error`. |

### 2.1 Error codes

| Code | Kind | Graded as |
|---|---|---|
| a reference domain code (`invalid_format`, `value_already_exist`, …) | domain | compared with `expected.error` (PASS when code — and field, if the vector gives one — match) |
| `charge_model_error` | domain (kit) | the reference raises instead of returning a value for this input |
| `parse_error`, `evaluation_error` | domain (kit) | expression language failures |
| `server_error`, `unknown_event_type`, `undecodable`, `invalid_timestamp` | domain (kit) | the other kit codes of `vector-format.md` section 4.4 (internal failure of the reference, unknown webhook event name, `ep` decoding and timestamp failures) |
| `unsupported_op` | protocol | SKIP (counts as not passed) |
| `bad_input` | protocol | ERROR: the input does not match the op schema as the adapter understands it |
| `internal` | protocol | ERROR: the implementation failed |

## 3. Timeouts, crashes and restarts

| Rule | Statement |
|---|---|
| AP-7 | Hello timeout 30 s (`--hello-timeout`): heavy runtimes may boot in that window (the lago-api oracle adapter boots in about 3 s). |
| AP-8 | Per-call timeout 5 s (`--timeout`); vectors tagged `slow` get 30 s (`--slow-timeout`); a vector may set `timeout_s`. |
| AP-9 | On timeout, EOF, a non-JSON line or a mismatched id, the runner records TIMEOUT or ERROR for that vector, kills the adapter's process group (SIGKILL), starts a new adapter (new hello) and continues with the next vector. The failing vector is not retried. |
| AP-10 | More than `--max-restarts` (default 20) restarts abort the run: `ABORT …`, exit 2. |
| AP-11 | A failed first hello (no answer, non-JSON, wrong type, wrong proto, missing profile, adapter exited) is a setup error: `SETUP-ERROR …`, exit 2. |

## 4. Versioning

- `proto` (integer) changes only when messages change incompatibly; the runner refuses a mismatch.
- `kit_schema` versions the vector envelope (`vector-format.md`).
- `kit_version` (semver, from `kit.json`) versions the op catalogue: minor versions add ops or optional input fields
  whose absence reproduces earlier behaviour; adapters ignore unknown optional fields that declare a default.

## 5. Runner CLI (`kitrun.py`)

```
kitrun.py --impl-cmd CMD [--kit-root DIR] [--vectors FILE ...] [--areas a,b] [--only REGEX]
          [--profile compat|corrected] [--include-holdout DIR] [--parallel N] [--timeout S] [--slow-timeout S]
          [--hello-timeout S] [--max-restarts N] [--report out.json] [--show-diff N] [--quiet] [--fail-fast]
          [--thresholds FILE]
```

| Option | Default | Effect |
|---|---|---|
| `--kit-root` | the directory holding `reimplementation-kit/` | vector discovery root: every `<kit-root>/<skill>/vectors/*.jsonl` |
| `--vectors` | discovery | explicit vector files instead of discovery |
| `--areas`, `--only` | all | filter by area list / regular expression on the vector id |
| `--profile` | `compat` | grades `both` + this profile's vectors |
| `--include-holdout DIR` | none | also run `DIR/*.jsonl` (maintainers only), reported in separate rows |
| `--parallel N` | 1 | N adapter processes |
| `--report FILE` | none | JSON report (`schemas/report.schema.json`) |
| `--show-diff N` | 3 | diff lines printed under each FAIL/ERROR/TIMEOUT |
| `--quiet` | off | print only non-PASS vector lines |
| `--fail-fast` | off | stop after the first FAIL/ERROR/TIMEOUT (exit 3) |
| `--thresholds` | `acceptance/thresholds.json` | per-area pass thresholds |

Output (illustrative run of an implementation under development):

```
kitrun 1.2.0 proto=1 kit=1.2.0 profile=compat vectors=153 files=2
impl=acme-billing 0.4.2 profiles=compat,corrected ops=3
PASS domain.selftest.days_between.001
…
FAIL pricing.graduated.011
    amount_details.graduated_ranges[2].units: expected "1.0" (numeric) got "2"
AREA                   TOTAL  PASS  FAIL ERROR TIMEOUT  SKIP UNRULED   RATE   CORE THRESH  VERDICT
domain                    23    23     0     0       0     0       0 100.0% 100.0% 100.0%  PASS
pricing                  130   127     2     1       0     0       0  97.7% 100.0%  98.0%  FAIL
SUMMARY kitrun: areas=2 pass=1 fail=1 vectors=153 passed=150 skipped_ops=0 exit=3
```

- `RATE` = PASS / (TOTAL − UNRULED); SKIP counts as not passed. `CORE` = pass rate of `core`-tagged vectors (must
  be 100 %). `THRESH` = the area's threshold for the set (shipped or holdout). `VERDICT` = PASS when RATE ≥ THRESH
  and CORE = 100 %; INFO when every vector of the area is UNRULED.
- `skipped_ops` = number of distinct ops that were skipped.
- Exit codes: **0** every area meets its threshold; **3** an area is below threshold, a core vector did not pass, or
  `--fail-fast` stopped the run; **2** setup or protocol error (adapter did not start or answer hello, proto or
  profile mismatch, too many restarts); **4** vector files invalid (unparsable line, missing envelope field,
  duplicate or malformed id) — run `validate-vectors.py` for details; **1** usage error (including an unknown
  `--areas` name, so a misspelt area can never pass vacuously, or an invalid `--only` expression). An empty
  selection prints `NOTE no vector selected …` and exits 0.

## 6. The report (`--report`)

`schemas/report.schema.json`: run metadata (`kitrun_version`, `proto`, `kit_version`, `started_at`, `finished_at`,
`impl` {cmd, name, version, profiles, ops, restarts}, `profile`, `selection`), `exit_code`, `areas[]` (one row per
area and set with the counts, `rate`, `core_rate`, `threshold`, `verdict`) and `vectors[]`
(`{id, area, op, set, status, unruled_outcome?, ms, diffs[], warnings[], adapter_error?, stderr_tail?}`). The report is
the artefact graders keep; `acceptance-and-grading.md` describes how it is read.

## 7. The scenario tier binding (`system.*`)

Scenario files are replayed by `scripts/scenario-replay.py` through five stateful ops on the same transport. The
normative definition (settings, tick vocabulary, snapshot content) is `scenario-tier.md` sections 3, 6, 7 and 9 and
`schemas/ops/system.*.schema.json`; this table is a summary:

| Op | Input | Output | Semantics |
|---|---|---|---|
| `system.reset` | `{organization: {...settings}, billing_entity?: {...settings}, premium: bool, store: pg\|ch}` | `{}` | erase every tenant of the adapter and create one empty tenant (one organization, one billing entity, one API key, no webhook endpoint) with the given settings |
| `system.set_clock` | `{now: instant}` | `{}` | every later effect uses this frozen wall clock |
| `system.api` | `{method, path, query?, body?}` | `{status: int, body: json\|null}` | one REST v1 call; returns only after all asynchronous follow-up work (jobs, webhooks) completed |
| `system.tick` | `{jobs: [names]}` | `{}` | run the named clock jobs (the vocabulary of `scenario-tier.md` section 6) at the current clock, in order, draining after each |
| `system.snapshot` | `{}` | `{invoices, credit_notes, wallets, wallet_transactions, subscriptions, fees}` | the tenant's state in API v1 serialisation; `fees` holds the fees not attached to an invoice |

Webhooks are not part of the snapshot: the scenario tier does not grade them (unit vectors of `webhooks.*` do).

A scenario-tier adapter is stateful by definition (AP-6 does not apply to `system.*`). An HTTP bridge
(`scenario-replay.py --http BASE_URL`) maps the same ops onto a running server with test-only clock and tick
endpoints; see `scenario-tier.md`.

## 8. The events-processor suite is a different harness

The events-processor is graded black-box by `events-processor-spec/scripts/run-suite.sh --impl-cmd "<command>"`:
the runner owns Kafka, Redis and a scratch Postgres database and starts the implementation as a long-running
consumer (also `sh -c "exec …"` in its own process group). Only the pure functions of the events-processor
(`ep.*` ops) use this adapter protocol. See `events-processor-spec` for that suite.

## 9. Transcripts

A minimal session (requests `>`, responses `<`), from the reference adapter skeleton `scripts/adapter_ref.py`:

```
> {"type":"hello","role":"runner","proto":1,"kit_version":"1.2.0-dev","kit_schema":1,"profiles":["compat"],"areas":["domain"]}
< {"type":"hello","proto":1,"impl":"adapter-ref-example","impl_version":"1.0.0","profiles":["compat","corrected"],"ops":["domain.round"]}
> {"type":"call","id":"domain.selftest.round.010#1","area":"domain","op":"round","profile":"compat","input":{"value":"-0.125","mode":"round","precision":2}}
< {"type":"result","id":"domain.selftest.round.010#1","output":{"value":"-0.13"}}
> {"type":"call","id":"domain.selftest.days_between.001#1","area":"domain","op":"days_between", …}     (not sent: op not declared → SKIP)
> {"type":"bye"}
```

Error and protocol cases the runner handles (each is a test in `scripts/selftest/test_runner.py`):

| Adapter behaviour | Runner result |
|---|---|
| exits during a call | that vector ERROR (`adapter crash: adapter exited (status 1)`), adapter restarted, next vectors run |
| sleeps past the timeout | that vector TIMEOUT, process group killed, adapter restarted |
| writes `this is not json` | that vector ERROR (`adapter garbage: …`), adapter restarted |
| answers with another call id | that vector ERROR, adapter restarted |
| prints a banner before hello | SETUP-ERROR, exit 2 |
| hello with `proto: 2` | SETUP-ERROR protocol mismatch, exit 2 |
| hello without the run's profile | SETUP-ERROR, exit 2 |
| crashes on every call | ABORT after `--max-restarts`, exit 2 |
| answers `unsupported_op` | SKIP |
| returns `{"value":"3"}` where `"2"` is expected | FAIL with `value: expected "2" (numeric) got "3"` |

## 10. Writing an adapter

- **Python**: import `scripts/adapter_ref.py` and call `serve({"area.op": handler}, impl=…, impl_version=…,
  profiles=[…])`. Helpers: `dec()` (exact decimal from string/int), `out_dec()` (canonical text), `round_half_away()`,
  `raw_json()` (parse a `*_json` field with Decimal numbers), exceptions `KitError(code, field)`, `Unsupported`,
  `BadInput`. `python3 scripts/adapter_ref.py` runs the worked example (`domain.round` only).
- **Other languages**: read stdin line by line; parse JSON with an exact-decimal number mode (Java `BigDecimal`
  via Jackson `USE_BIG_DECIMAL_FOR_FLOATS`, Go `json.Decoder.UseNumber`, JavaScript a big-decimal reviver or
  `json-bigint`); write one line per request and flush; route logs to stderr; exit on `bye`.
- **Services**: an adapter may be a thin client (stdin → HTTP/gRPC call → stdout). Keep the process alive across
  calls; startup cost is paid once per process (the hello timeout is 30 s).
- **Time**: never read the wall clock inside an op; every time-dependent op receives its instant in `input`.
- Start with `kitrun.py --impl-cmd "<adapter>" --areas domain` and grow area by area (`method.md`).

## Provenance (maintainers)

- Protocol of record: the kit plan of record (2026-10-02) section 3; process handling (process group, `exec`,
  quiescence without fixed sleeps) adopted from the events-processor black-box runner.
- Verified 2026-10-02: `python3 scripts/selftest/test_runner.py` → `Ran 18 tests … OK`; the lago-api oracle adapter
  (`scripts/maintainer/oracle.sh adapter`) answered hello in about 3 s and the 23 self-test vectors 23/23 PASS.
- Section 7 aligned with the scenario tier's `system.*` schemas on 2026-10-02 (snapshot key `fees`, optional
  `billing_entity` on reset); the oracle's `system` module answers exactly those shapes.
- Update triggers: any message change (bump `proto`), a new protocol error code, a runner exit-code change.
