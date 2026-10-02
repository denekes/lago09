# KIT-GAPS (crc-4a)

1. **Default metric code.** `aggregate` input has no metric `code` but events may carry `code`. Where I looked: schema
   `aggregation.aggregate`, BE-AG-1. Assumption: the metric code defaults to a fixed string; events without `code` match,
   events with any explicit code differ (core.count.005 passes).
2. **Per-event values of prorated sums.** BE-AG-21 says window events only, but the prorated vector lists the carried
   total as a first entry. Assumption: prorated lists = [carried sum (if any carried events)] + window events.
3. **Grouped prorated unique "extra day".** BE-AG-52 does not say per value or per group. Assumption: one day per
   value added and removed before the window (relational store, grouped, compat only).
4. **Cached-state window check.** BE-AG-40 says a cache counts only if its timestamp lies in the window (whole
   seconds); applied for aggregate/in_advance_units; no vector contradicts it.
5. **`count` for unique-count current usage in advance** equals the clamped aggregation (vector current.005), not stated in the chapter.
6. **Corrected profile RBD-36 (select_events twin 008x)** not implementable from the op input alone (needs sibling filters); left failing (unruled).
7. **Weighted sum digits.** Per-group sums are "without the ceiling"; I compute the exact sum and ceil at 20 places for ungrouped; results are only normative to 12 places.
