# KIT-GAPS (crc-3)

1. **Batch duplicate detection, compat (BE-EV-43/44).** Rule says repeats are matched on `transaction_id` alone
   and the error lands on the later index, but does not say how many events are flagged when a stored key
   and several batch events share a transaction id. Looked at: chapter 02 §5, vectors 006/007/008/012/014.
   Assumption: per transaction id with n batch events, flag the last max(n-1, 1 if a stored event has that id else 0).
2. **Pre-1970 event with an expression** (BE-EX-32 "evaluate like any other" vs BE-EV-54 "corrected rejects with 422").
   Assumption: compat answers HTTP 500, corrected evaluates normally. Not graded.
3. **Division by zero in compat** (internal error, ungraded): events ops answer HTTP 500 in compat, 422 in corrected;
   `expression.evaluate` answers `evaluation_error` in both profiles.
4. **Non-finite / out-of-range timestamps** (BE-EV-15): answered `invalid_format` in both profiles (the "rebuild"
   answer). Range limited to years 1..9999 (Python datetime); the reference range is wider.
5. **`precise_total_amount_cents` in `stored_event`**: text form not fixed for integers; I use the BE-EV-62 form
   (at least one fractional digit, e.g. `"5.0"`).
6. **Expression with ep surface:** whether an absent `properties` fails is unstated (only null is). Assumption: absent = `{}`.
   A non-string `event.code` on the ep surface is treated as the empty string.
7. **Blank expression on the rails surface** of `expression.evaluate` is unspecified; it yields `parse_error`.
8. **Whitespace around expressions** (leading/trailing spaces) assumed allowed.
9. **Property-name collision with numeric strings:** `to_value` converts numeric strings on every read, including
   when the bare property is the result (`"1.0"` becomes a number 1.0). Taken from the pseudocode in BE-EX §7.

## v1.1

No open questions block the v1.1 vectors. Residual, all resolved by the new rules:

- Is a hand-built `event` (not `event_json`) on the ep surface subject to the same member checks as the JSON form?
  Looked at: BE-EX-40. Assumption: yes (code must be a string, timestamp non-null, properties an object of numbers and strings).
- BE-EV-44: are keys of already-flagged batch events counted as "earlier" keys for later events? Looked at: BE-EV-43/44.
  Assumption: yes, every earlier event's key counts.
