# crc-9 — Lago events-processor (Python 3.12, DB mode)

Clean-room implementation from the kit pack only. DB mode only (memory-cache mode is out of scope; with
`LAGO_USE_MEMORY_CACHE=true` the process still runs in DB mode). Default profile: **corrected** (ADR-001 delivery).

## Setup

```bash
/usr/bin/python3.12 -m venv impl/crc-9/.venv
impl/crc-9/.venv/bin/pip install -r impl/crc-9/requirements.txt
```

## Commands (from the repository root)

| Purpose | Command line |
|---|---|
| processor (`--impl-cmd` of run-suite.sh) | `impl/crc-9/.venv/bin/python impl/crc-9/processor.py` |
| ep adapter (`--impl-cmd` of kitrun.py) | `impl/crc-9/.venv/bin/python impl/crc-9/adapter.py` |

```bash
.claude/skills/events-processor-spec/scripts/run-suite.sh \
  --impl-cmd "impl/crc-9/.venv/bin/python impl/crc-9/processor.py" --mode db --profile both --loose-errors
python3 .claude/skills/reimplementation-kit/scripts/kitrun.py \
  --impl-cmd "impl/crc-9/.venv/bin/python impl/crc-9/adapter.py" --areas ep --profile compat
# compat (migration) behaviour of the processor: a separate process profile, selected by environment
.claude/skills/events-processor-spec/scripts/run-suite.sh \
  --impl-cmd "impl/crc-9/.venv/bin/python impl/crc-9/processor.py" --impl-env EP_PROFILE=compat \
  --mode db --profile compat --loose-errors
```

`GOTOOLCHAIN=auto` is needed once so the kit's Go runner builds (it needs Go >= 1.25).

## Files

- `ep_core.py` — pure rules: decode (literal-preserving JSON), timestamps, value text, subscription matching,
  commit rule, refresh member; every function takes `profile` (`corrected` | `compat`).
- `expr.py` — the expression language (exact decimals, number text form, 100-digit division).
- `processor.py` — Kafka consumer/producers, Postgres catalog reads, Redis flag, delivery logic.
- `adapter.py` — kitrun adapter for `ep.decode`, `ep.parse_timestamp`, `ep.value_string`,
  `ep.match_subscription`, `ep.commit_offset`, `ep.refresh_member` (both profiles).

## Design (corrected profile)

One ordered worker per process. Each record is taken to a durable disposition before its offset is committed:

- PERMANENT (undecodable → dead letter with `raw_event`; bad timestamp; unknown metric; expression failure;
  record-specific broker rejection of the enriched record) → dead letter with a non-empty `error_code` at once.
- Lookup/Redis/produce failures → retried **in place** (3 attempts, 0.1 s doubling, jittered), then the worker blocks
  and retries with backoff 0.25 s → 2 s (`EP_BACKOFF_MAX_S`) until the dependency answers; nothing after the failing
  record is processed or committed. A record whose `ingested_at` is 12 h old or more is dead-lettered
  (`retry_exhausted:<code>`) once the in-place attempts are used up; unknown age keeps retrying (KQ-4 assumption).
- A refused dead-letter produce and a refused in-advance produce never skip the record: the worker waits and retries.
- Order per record: enriched produce (acks=all, waited for) → charge lookup → in-advance produce → refresh flag; a retry
  repeats only the failing step.
- Offsets are committed synchronously after every batch for the prefix of finished records; SIGTERM finishes the
  in-flight record, commits, leaves the group and exits 0. Startup failures exit with status 2 before the group join.
- No retry topic is published (KQ-1): the retry state lives in the blocked worker (head-of-line blocking by design).

Environment knobs (all optional): `EP_PROFILE` (`corrected`|`compat`), `EP_INPLACE_ATTEMPTS`, `EP_INPLACE_BASE_S`,
`EP_BACKOFF_BASE_S`, `EP_BACKOFF_MAX_S` (default 2), `EP_RETRY_MAX_AGE_S` (default 43200), `EP_PRODUCE_TIMEOUT_S`,
`EP_BATCH`, `EP_IDEMPOTENT` (default off, see KIT-GAPS).
