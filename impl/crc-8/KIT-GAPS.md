# KIT-GAPS (crc-8)

1. **Full list of the 75 configured webhook event names.** Question: which exact names are valid filter values / known to `type_info`? Looked in: billing-engine-spec ch. 12 section 3 and the out-of-scope paragraph (wildcards `payment.*`, `payment_receipt.*`, `payment_request.*`, `feature.*`, `quote.*`, `order.*`, `order_form.*`), appendix-enums. Assumption: the 40 enumerated in-scope names plus the enumerable out-of-scope ones; the wildcard families are expanded by guess (e.g. `payment_request.created`), and their object_type is a guess. Only the in-scope names are pinned by the kit.
2. **`webhooks.payload_envelope` output keys `status`.** The schema lists `status` but no rule defines it; I return `"pending"` (BE-WH-27 initial delivery status).
3. **Minute-pinned job at the window edge.** BE-CK-2 says "first instant whose minute matches"; for a window starting mid-minute (e.g. 00:05:30) I count the pinned minute as run (clockwork-style, minute slot overlapping [from, to)). Unpinned by vectors.
4. **Corrected profile for `jobs_due`.** RBD-79 proposal implemented as: wallet refresh always scheduled unless `LAGO_DISABLE_WALLET_REFRESH` is truthy.
5. **Env truthiness** (`LAGO_DISABLE_*`, `LAGO_CLICKHOUSE_ENABLED`): not specified; I accept true/1/yes/on, case-insensitive.
6. **Count-cache key for fees** lists `succeeded_at_from` etc.; the schema and chapter agree, but fee `page` handling follows the invoices rule (removed). Non-scalar values for scalar filters are dropped.

## v1.1

No open questions for webhooks, api, clock. Minor assumption: the `jobs_due` window is `[from, to)` and a fractional-second start keeps its fraction on every tick (BE-CK-2 says "whole second after it"; read in `13-clock-and-async.md`; no vector contradicts it).
