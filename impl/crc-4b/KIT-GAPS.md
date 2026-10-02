# KIT-GAPS (crc-4b)

1. **Metric code of an event.** The op schema has no metric `code`, yet vectors give events an explicit `code`
   (BE-AG-1). Looked at: aggregate schema, aggregation.core.count.005. Assumption: an event with an explicit `code`
   is excluded unless it equals `metric.code` (absent in practice); events without `code` always match.
2. **Corrected profile, grouped prorated sums.** `aggregation.prorated.sum.011` is a `both` vector expecting the
   binary64 island (1.10001) for a grouped bucket, while the ungrouped twin `island.001x` expects the exact 1.1 under
   corrected. Looked at: BE-AG-56, RBD-96. Assumption: grouped prorated sums keep the island in both profiles.
3. **`active-before` with equal timestamps (BE-AG-41).** "latest strictly earlier event" is ambiguous for equal
   times. Assumption: earlier = smaller (timestamp, ingestion order).
4. **Cache timestamp for weighted sums (BE-AG-18).** `cached.timestamp` defaults to `window.from`, which is not
   "strictly before from", so a cache without a timestamp is ignored by weighted sums. Assumption as written.
5. **Corrected `select_events` of overlapping filters (select.008x) and corrected weighted precision (store_ch
   gate.007x)** cannot be derived from the op input / expected text (unruled vectors); not implemented.
6. **Prorated unique, grouped pg quirk (BE-AG-52).** Implemented as "+1 day for a value added and removed before
   the window, per group" (pg, compat, grouped only); no shipped vector pins the exact form beyond ch.prorated.004.
