# KIT-GAPS (crc-9)

Format: question; where I looked; assumption made.

1. **Compat ≥ 90 % and corrected 100 % with one command line.** `run-suite.sh --profile both` runs one IUT command for
   both profiles, but compat goldens require the reference's silent-loss and quirk behaviour (e.g. EPC-10 commit past an
   unprocessed record, `<nil>` value text) while the corrected assertions forbid it. Looked: SKILL.md §8 grading table,
   conformance-suite.md §8/§9 (the Python corrected self-test IUT matches only 9/30 compat goldens). Assumption: the
   processor is corrected by default; `EP_PROFILE=compat` (env, via `--impl-env`) switches the same binary to reference
   behaviour so each threshold can be measured on its own run. With the single default command compat is 13/30.
2. **Idempotent producer vs the in-process broker.** After the runner's INVALID_RECORD answer, an idempotent librdkafka
   producer (2.15.1) fails every later produce with `UNKNOWN_LEADER_EPOCH` (EPC-18/19/20 never finish). Looked:
   contract.md EP-A7 (reference producer is idempotent), conformance-suite.md gotcha 1. Assumption: default
   `enable.idempotence=false`, `acks=all`, one in-flight request, one synchronous produce at a time (`EP_IDEMPOTENT=1`
   turns it on); duplicates can only come from an acknowledgement lost after the broker wrote (downstream
   idempotency on `transaction_id` is required anyway, EP-R7).
3. **Backoff cap vs the suite's settle window.** EP-R3 says backoff 1 s → 60 s, but the suite treats 3 s without change
   as quiescent while records are uncommitted, so a retry that lands later than ~3 s after the runner clears a fault is
   judged too late (EPC-17/19/20). Assumption: cap 2 s by default (`EP_BACKOFF_MAX_S`), first retry 0.25 s.
4. **Pause semantics.** "Pause the affected partitions" – I block the single worker instead of calling `pause()`;
   `max.poll.interval.ms` is set to 1 h so a long outage does not evict the member. Polling while holding fetched
   records could drop them, so the worker never polls during a block.
5. **Dead-letter shape for undecodable records.** wire-formats.md §4 gives `raw_event` as an additive field but no
   other names (KQ-5). Assumption: `{"raw_event", "error_code":"decode_raw_event", "error_message":"Error decoding raw
   event", "initial_error_message", "failed_at"}` and no `event` object. I also add `raw_event` to the dead letter of
   the `null` literal (empty `transaction_id`) so the ledger can attribute it by bytes.
6. **Error codes of new causes.** Assumed `produce_rejected` (enriched record refused by the broker),
   `retry_exhausted:<code>` (age horizon), `decode_raw_event`.
7. **Age of a record without `ingested_at` (KQ-4).** Assumed: never dead-lettered by age; keeps retrying
   (either EPC-13 outcome passes; one-shot faults are absorbed in place).
8. **Zero in the number text form.** BE-EX-21 (d) says the processor build keeps the scale of zero (`0.00`) but rules
   (a)/(b) would print `0E-8` for a zero with a large scale and (c) a run of zeros for a negative scale. Assumption:
   zero is always plain (`0`, `0.00`, `0.00000000`; negative scale → `0`).
9. **Expression input numbers.** EP-C5 (binary64 re-encoding) vs RBD-14 (literal) for numbers the engine sees.
   Assumption: corrected = integer literals exact, other numbers via their binary64 shortest text; compat = binary64
   for all. Numeric-string syntax BE-EX-11: underscores allowed after the first digit of the mantissa only.
10. **Proposed rulings.** Where a corrected twin is `proposed` (RBD-14 literal numbers in `properties`, RBD-18 truncated
    JSON-number timestamp, RBD-99 exact external id, RBD-7 in-advance rejection) the corrected profile follows the
    twin. Hex/`NaN`/`Inf` timestamps: rejected (corrected), `NaN`/`Inf` silently dropped and hex accepted (compat only).
11. **Case-insensitive JSON keys.** The reference's decoder may match field names case-insensitively; the kit does not
    say. Assumption: exact, case-sensitive names.
12. **Instant of a negative timestamp.** Emitted text truncates toward zero (EP-D2); the matching instant is floored to
    the millisecond (kit silent). Values with |seconds| ≥ 1e17 are rejected as invalid timestamps (kit silent).
13. **Non-UUID organization id.** The reference's behaviour is not stated; assumed "metric not found" dead letter
    (`record not found`) without querying.
14. **Retry topic.** Not implemented (KQ-1); see README design notes.
