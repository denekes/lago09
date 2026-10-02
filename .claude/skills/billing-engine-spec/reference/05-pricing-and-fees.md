# 05 — Pricing and fees (BE-PR)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. This chapter specifies how the billing engine prices the units of one charge bucket
(the **charge models**), how a pricing result becomes a **fee** (money fields, stored units, persistence), the
incremental pricing of charges billed **in advance**, the charge **minimum** true-up, **pricing units**, **fixed
charges**, property **validation**, defaults and slicing, **projections**, instant **estimates** and the price
**simulator**. Units come from chapter 04 (aggregation); billing windows and day counts from chapters 06 and 01;
taxes, coupons and invoice totals from chapter 07.

Reading guide: rules are numbered `BE-PR-n`; every rule line ends with `[vec: …]` naming the vectors that pin it, or a
prose-only marker with the reason. Vector files (all in `billing-engine-spec/vectors/`): `pricing.models.jsonl`
(op `pricing.charge_model`), `pricing.in_advance.jsonl` (`pricing.pay_in_advance`), `pricing.fees.jsonl`
(`pricing.fee_money`, `pricing.true_up`, `pricing.pricing_unit`), `pricing.validation.jsonl`
(`pricing.validate_properties`, `pricing.validate_charge`, `pricing.default_properties`, `pricing.filter_properties`),
`pricing.fixed_charges.jsonl` (`pricing.fixed_charge_units`, `pricing.fixed_charge_fee`,
`pricing.fixed_charge_in_advance`) and `pricing.misc.jsonl` (`pricing.projection`, `pricing.estimate_instant`,
`pricing.simulate`). Input and output schemas: `reimplementation-kit/schemas/ops/pricing.*.schema.json` (each schema's
description restates the op in one paragraph).

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Concepts and the pricing contract

| Term | Meaning |
|---|---|
| charge | a priced item of a plan: a billable metric, a **charge model**, model **properties**, flags `pay_in_advance`, `prorated`, `invoiceable`, optional `min_amount_cents` (minimum), optional pricing unit, optional charge filters |
| charge model | `standard`, `graduated`, `graduated_percentage`, `package`, `percentage`, `volume`, `dynamic`, `custom` (stored codes in `appendix-enums.md`) |
| properties | JSON object of model parameters. Decimal parameters are **JSON strings** (`"5.12345"`); counts and range bounds are JSON numbers. Also carries the grouping keys (`pricing_group_keys`, deprecated `grouped_by`, `presentation_group_keys`) |
| bucket | what one fee prices: the whole charge, one of its charge filters, or the charge's default bucket (chapter 04 section 6); with grouping, one group inside a bucket |
| U | `units` of the bucket from chapter 04 (after metric rounding; prorated when the charge is prorated) |
| FU | `full_units_number`: units without proration; may be absent |
| C | `count`: number of events of the bucket |
| RT | `running_total`: cumulative event values in time order (chapter 04 BE-AG-20), the percentage model's free-unit helper |
| per-event values | values of the bucket's events in time order (chapter 04 BE-AG-21); per-transaction percentage and prorated graduated use them |
| currency | the plan currency; `e` = its exponent, `s = 10^e` (chapter 01 BE-DM-21) |
| premium | the reference's premium licence flag; gates several features (BE-PR-86). Vector input `premium: true` |
| half away | round half away from zero on exact decimals (chapter 01 BE-DM-23) |

- **BE-PR-1** A charge model is a pure function of (model, properties, currency, prorated flag, the bucket's aggregation result, period ratio, projection flag). It returns `amount` in major units **unrounded**, `unit_amount`, `amount_details` (model specific, section 12 for its stored form) and passes `units`, `full_units_number`, `current_usage_units`, `count` and `total_aggregated_units` through. Arithmetic is exact decimal; a decimal division keeps at least 32 significant digits, the last one rounded (`1300 / 121 = 10.743801652892561983471074380165`, `163 / 21 = 7.7619047619047619047619047619048`; operands longer than 16 significant digits give longer quotients); the binary-float exceptions are listed in BE-PR-85. Vectors compare unit amounts to 15 decimal places (the stored precision). [vec: pricing.graduated.004, pricing.package.001, pricing.standard.001, pricing.standard.007]
- **BE-PR-2** The properties priced for a bucket are those of the matching charge filter, else the charge's; the default bucket (events matching no filter) uses the charge's properties and the charge's grouping keys. Every bucket and every group is priced independently: tiers, packages and free units restart per bucket (BE-PR-5). [vec: none (prose only: the bucket and its properties are inputs of every pricing op; bucket selection is chapter 04 section 6)]
- **BE-PR-3** The pricing currency is the plan currency; it matters only where a model or a fee converts between major and minor units (dynamic model, money fields). [vec: pricing.fee_money.006]
- **BE-PR-4** Dispatch: each model maps to its algorithm. `graduated` with `prorated = true` uses the **prorated graduated** algorithm (section 9) only when per-event data is available; without it (forecasts, the simulator) it prices as plain graduated. Pay in advance uses its own map (BE-PR-45). An unknown model is a validation error (BE-PR-79). [vec: pricing.prorated_graduated.011]
- **BE-PR-5** Grouping: when the properties carry grouping keys (`pricing_group_keys`, else `grouped_by`) or the charge accepts target wallets, and the aggregation returned a per-group list, every group is priced on its own with the bucket's model and properties; the bucket result is `amount = Σ group amounts`, `units = Σ group units` (projections summed too) and the group results (with their `grouped_by` values, `null` allowed) become separate fees. With grouping keys but no per-group list the model prices the totals once. [vec: pricing.grouped.001, pricing.grouped.002, pricing.grouped.003, pricing.grouped.004, pricing.grouped.005, pricing.grouped.006]

## 2. Standard

- **BE-PR-6** `amount = U × amount` (property `amount`). Negative units give a negative amount (the fee step clamps it, BE-PR-52). `amount_details = {}`. [vec: pricing.standard.001, pricing.standard.003, pricing.standard.004, pricing.standard.006, pricing.standard.007]
- **BE-PR-7** Unit amount of standard, graduated, graduated percentage, percentage, dynamic and custom: `unit_amount = amount / D` with `D = FU` when FU is present, else `U`; `unit_amount = 0` when `D = 0` (even if the amount is not 0). [vec: pricing.standard.001, pricing.standard.002, pricing.standard.004]

## 3. Package

Properties: `amount` (price of one package), `package_size` (integer > 0), `free_units` (integer ≥ 0).

- **BE-PR-8** `paid = U − free_units`. If `paid < 0` the amount is 0. Otherwise `amount = packages × amount` with `packages = ceil(paid / package_size)`: a started package is billed in full (10.0001 units at size 10 = 2 packages; exactly 10 = 1). Free units restart per bucket and per group. [vec: pricing.package.001, pricing.package.002, pricing.package.010]
- **BE-PR-9** The package count is computed in **binary floating point**: `paid` is converted to binary64 before the division (BE-PR-85), so 10.00000000000000001 paid units at size 10 count as 1 package (RBD-43; corrected profile: exact decimal ceiling, 2 packages). [vec: pricing.package.008, pricing.package.008x]
- **BE-PR-10** `unit_amount = amount / paid` when `paid > 0`, else 0 — per **paid** unit, unlike every other model. [vec: pricing.package.001, pricing.package.002, pricing.package.009, pricing.package.010]
- **BE-PR-11** Details: at `U = 0` the literal zero shape `{free_units: "0.0", paid_units: "0.0", per_package_size: 0, per_package_unit_amount: "0.0"}`; when `paid < 0`: `free_units` (the property), `paid_units: "0.0"`, the package size and price; otherwise `free_units`, `paid_units`, `per_package_size` (integer) and `per_package_unit_amount`. [vec: pricing.package.001, pricing.package.002]

## 4. Graduated (each tier priced separately)

Properties: `graduated_ranges`, a list of `{from_value, to_value, per_unit_amount, flat_amount}`; the last `to_value`
is `null` (validation, BE-PR-76).

- **BE-PR-12** Ranges are walked **in the stored order** (never sorted; validation guarantees ascending order). For each range a tier detail is appended; the walk stops after the first range whose `to_value` is null or `≥ U`. Hence units exactly equal to a range's `to_value` stay in that range; the next range (and its flat amount) is reached only above it. [vec: pricing.graduated.001, pricing.graduated.002, pricing.graduated.003, pricing.graduated.004, pricing.graduated.011, pricing.graduated.014]
- **BE-PR-13** Adjacency: the ranges are **adjacent** when there are at least two of them and every `from_value` equals the previous `to_value` (a null previous `to_value` reads as 0). Adjacent ranges (`[0,10],[10,20],…`, also decimal bounds like `[0,0.1],[0.1,1]`) and the integer convention (`[0,10],[11,20],…`) price integer units identically. [vec: pricing.graduated.006, pricing.graduated.007, pricing.graduated.008, pricing.graduated.011]
- **BE-PR-14** Units of a tier: `eff = to_value` when `to_value` is not null and `U ≥ to_value`, else `U`; tier units = `eff` when `from_value = 0`, otherwise `eff − from_value`, plus 1 unless the ranges are adjacent. Fractional usage between two integer-convention tiers falls in the upper tier (10.5 units over `[0,10],[11,20]` = 10 + 0.5). [vec: pricing.graduated.002, pricing.graduated.003, pricing.graduated.004, pricing.graduated.006, pricing.graduated.007, pricing.graduated.008, pricing.graduated.009, pricing.graduated.010, pricing.graduated.014]
- **BE-PR-15** Tier detail: `{from_value, to_value, flat_unit_amount = flat_amount, per_unit_amount (0 when the tier has 0 units, else the price), units, per_unit_total_amount = units × per_unit_amount, total_with_flat_amount = per_unit_total_amount + flat_unit_amount}`; `amount = Σ total_with_flat_amount`; `amount_details = {graduated_ranges: [tier details]}`; unit amount per BE-PR-7. [vec: pricing.graduated.001, pricing.graduated.002, pricing.graduated.003, pricing.graduated.004]
- **BE-PR-16** The flat amount of a reached tier is charged even with 0 units in it: **at zero usage the first tier's flat amount is billed** (a fee with units 0 and a non-zero amount; RBD-48 keeps this). A first tier with flat 0 and price 0 bills 0. Volume and graduated percentage behave the same. [vec: pricing.fixed_charge_fee.006, pricing.graduated.001, pricing.graduated.005]
- **BE-PR-17** Pay-in-advance baseline: with the flag `exclude_event` (BE-PR-43) and `U = 0` the amount is 0 (no flat amount), so the first event of a period pays the first tier's flat. [vec: pricing.graduated.012]

## 5. Graduated percentage (premium)

Properties: `graduated_percentage_ranges`, a list of `{from_value, to_value, rate, flat_amount}` (`rate` in percent;
default properties also carry an unused `fixed_amount`).

- **BE-PR-18** Same walk and stop rule as BE-PR-12. [vec: pricing.gp.001, pricing.gp.002, pricing.gp.003, pricing.gp.004]
- **BE-PR-19** Tier units **ignore adjacency**: if `to_value` is not null and `U ≥ to_value` → `to_value − (1 if from_value = 0 else from_value) + 1`; else if `from_value = 0` → `U`; else `U − from_value + 1`. With adjacent bounds this counts one unit more than graduated (15 units over `[0,10],[10,∞)` give 10 + 6 tier units) and with JSON-float bounds the subtraction happens in binary floating point (0.5 units over `[0,0.1],[0.1,1]` give tier units 0.09999999999999998 and 1.4). RBD-42 (corrected profile, proposed: graduated adjacency rule and exact decimals). [vec: pricing.gp.001, pricing.gp.002, pricing.gp.003, pricing.gp.005, pricing.gp.006, pricing.gp.006x, pricing.gp.008, pricing.gp.009, pricing.gp.009x]
- **BE-PR-20** Tier detail `{from_value, to_value, flat_unit_amount, rate, units, per_unit_total_amount = units × rate / 100, total_with_flat_amount = per_unit_total_amount + flat}`; `amount = Σ total_with_flat_amount`; `amount_details = {graduated_percentage_ranges: [...]}`; unit amount per BE-PR-7. [vec: pricing.gp.001, pricing.gp.002, pricing.gp.003, pricing.gp.004, pricing.gp.005]
- **BE-PR-21** With `exclude_event` and `U = 0` every tier detail's `flat_unit_amount` and `total_with_flat_amount` are 0, so the amount is 0. [vec: pricing.gp.007]

## 6. Volume (all units at the price of the tier reached)

Properties: `volume_ranges` with the same keys as graduated ranges.

- **BE-PR-22** Ranges are **sorted by `from_value`** first. `N = FU` when the charge is prorated and FU is present, else `U`. [vec: pricing.fixed_charge_fee.004, pricing.volume.006, pricing.volume.010]
- **BE-PR-23** The matching range is the first with `from_value ≤ ceil(N)` and (`to_value` null or `N ≤ to_value`). Values in an integer gap therefore fall into the upper tier (100.5 → the range starting at 101; RBD-49 keeps this). [vec: pricing.volume.001, pricing.volume.002, pricing.volume.003, pricing.volume.011]
- **BE-PR-24** `per_unit_total = U × per_unit_amount` of the matched range (prorated: tier chosen by full units, price applied to the prorated units), `amount = per_unit_total + flat_amount`; `unit_amount = amount / N`, 0 when `N = 0`. The first range's flat applies at zero units (BE-PR-16). [vec: pricing.volume.001, pricing.volume.002, pricing.volume.003, pricing.volume.006]
- **BE-PR-25** Details `{flat_unit_amount, per_unit_amount, per_unit_total_amount}`; `per_unit_amount` is 0 when `N = 0`, otherwise the text of `binary64(per_unit_total) / N` (the numerator is converted to binary64 first, BE-PR-85, then divided in decimal: price 0.333333333333333333 × 3 units shows `0.33333333333333333333333333333333`). [vec: pricing.volume.001, pricing.volume.002, pricing.volume.006, pricing.volume.007, pricing.volume.008]
- **BE-PR-26** Negative `N` matches no range and the reference fails (no fee can be computed for the bucket). RBD-44 (corrected profile, proposed: price to 0). [vec: pricing.volume.009, pricing.volume.009x]

## 7. Percentage

Properties: `rate` r (percent), optional `fixed_amount` f (per paid event, default 0), `free_units_per_events` FE
(integer, default 0), `free_units_per_total_aggregation` FA (decimal, default 0), and the premium per-transaction
bounds `per_transaction_min_amount` / `per_transaction_max_amount`.

- **BE-PR-27** Free units `free`: let `last` = the last element of RT (0 when RT is empty). Apply the first matching case: `last = 0` → 0; `FE > 0` and `FE < |RT|` → `RT[FE − 1]`; `FA = 0` → `last`; `last ≤ FA` → `last`; otherwise `FA`. (RT itself is built by chapter 04 BE-AG-20 from FE and FA.) [vec: pricing.percentage.001, pricing.percentage.002, pricing.percentage.004, pricing.percentage.013, pricing.percentage.014, pricing.percentage.015]
- **BE-PR-28** Free events `FC` = the smallest non-zero value of {FE, number of RT entries strictly below FA}; 0 when both are 0. An event that brings the running total to exactly FA is therefore a **paid** event for the fixed fee. [vec: pricing.percentage.001, pricing.percentage.002, pricing.percentage.004, pricing.percentage.012, pricing.percentage.013, pricing.percentage.014, pricing.percentage.015]
- **BE-PR-29** `P = 0` when `free > U`, else `(U − free) × r / 100`. `F = 0` when `U = 0` or `FC ≥ C`, else `(C − FC) × f`. `amount = P + F` (unless BE-PR-30 applies). [vec: pricing.percentage.001, pricing.percentage.002, pricing.percentage.003, pricing.percentage.011, pricing.percentage.012]
- **BE-PR-30** Per-transaction mode applies only with the premium licence **and** a non-blank minimum or maximum. Start with `rfe = FE`, `rfa = FA` and visit each per-event value `v` once, in order: if `rfe > 0` or `rfa > 0` (otherwise the whole event is paid): decrement `rfe`; then if `rfa ≤ 0` the event is free; else if `rfa > v` then `rfa −= v` and the event is free; else `v −= rfa`, `rfa = 0`, `rfe = 0` and the rest of the event is paid. A paid value prices `e = v × r / 100 + f`, then `e = min` when a minimum is set and `e < min`, else `e = max` when a maximum is set and `e > max` (free events are never raised to the minimum). `amount = Σ e`. Note that FA keeps covering events beyond the first FE (RBD-41: two free-unit semantics; corrected profile, proposed: the BE-PR-27 semantics). Without premium the bounds are ignored. [vec: pricing.in_advance.023, pricing.in_advance.024, pricing.in_advance.025, pricing.percentage.007, pricing.percentage.008, pricing.percentage.016, pricing.percentage.016x, pricing.percentage.018]
- **BE-PR-31** Details always come from the BE-PR-27..29 computation: `units = U`, `free_units = free`, `free_events = min(C, FC)`, `paid_events = C − free_events`, `paid_units = max(U − free, 0)`, `rate`, `per_unit_total_amount = P`, `fixed_fee_unit_amount = f` when `paid_events > 0` else 0, `fixed_fee_total_amount = F`, `min_max_adjustment_total_amount = amount − P − F` in per-transaction mode, else 0. A zero amount with stale running totals still reports the free units and events (zero units, RT `[50,150,400]`: free 250, 2 free and 2 paid events, fixed total 0). [vec: pricing.percentage.001, pricing.percentage.002, pricing.percentage.003, pricing.percentage.007, pricing.percentage.008, pricing.percentage.010, pricing.percentage.016, pricing.percentage.016x]
- **BE-PR-32** Unit amount per BE-PR-7 (`amount / (FU or U)`). [vec: pricing.percentage.002]

## 8. Dynamic and custom

- **BE-PR-33** Dynamic (sum metrics only, BE-PR-79): `amount = precise_total_amount_cents / s` where `precise_total_amount_cents` is the sum of the events' own amounts in minor units (chapter 02/04) and `s` the plan currency's subunit (JPY 1, KWD 1000); `amount = 0` whenever `FU or U` is 0, even if the events carry amounts. Properties carry only grouping keys. Unit amount per BE-PR-7. [vec: pricing.in_advance.029, pricing.in_advance.030, pricing.dynamic.001, pricing.dynamic.002, pricing.grouped.002, pricing.validate_charge.017]
- **BE-PR-34** Custom (custom metrics only): `amount` = the amount computed by the metric's custom aggregation (0 when absent); unit amount `amount / (FU or U)`, 0 when that is 0. The custom aggregator itself is out of scope (RBD-98). [vec: pricing.custom.001, pricing.custom.002, pricing.validate_charge.018]

## 9. Prorated graduated

Used for a prorated graduated charge (recurring metric, billed in arrears) when per-event data is available. Inputs:
the ranges, `U` (prorated total) and two parallel per-event lists from chapter 04: `full[i]` (signed unit change of
event i) and `pro[i]` (that change weighted by the remaining fraction of the period).

- **BE-PR-35** Algorithm: the pseudocode below (written fresh; `coef(k) = binary64(pro[k]) / full[k]`, BE-PR-85). [vec: pricing.prorated_graduated.001, pricing.prorated_graduated.003, pricing.prorated_graduated.005, pricing.prorated_graduated.006, pricing.prorated_graduated.007, pricing.prorated_graduated.008, pricing.prorated_graduated.009, pricing.prorated_graduated.010]

  ```
  if U = 0: return flat(peak = 0)                                  # BE-PR-36
  i = 0; overflow = 0; fs = 0; peak = 0; ps = 0; acc = 0
  loop while i < n or overflow ≠ 0:
      r = select(fs, overflow, full[i] if i < n else none)
      if overflow ≠ 0:
          ps += overflow × coef(i−1)
          if r.to ≠ null and fs ≥ r.to:
              overflow = fs − r.to; ps −= overflow × coef(i−1); acc += ps × r.price; ps = 0
              continue
          overflow = 0
      if i ≥ n: break
      if pro[i] = 0 and full[i] > 0: i += 1; continue               # add with zero weight
      if pro[i] = 0 and full[i] < 0 and fs + full[i] < 0: i += 1; continue   # orphan removal
      fs += full[i]; peak = max(peak, fs); ps += pro[i]; i += 1
      if (r.to = null and fs ≥ r.from − 1) or (r.from ≤ fs < r.to): continue
      overflow = (r.to = null) ? fs − r.from + 1 : (fs ≥ r.to ? fs − r.to : fs − r.from + 1)
      ps −= overflow × coef(i−1); acc += ps × r.price; ps = 0
  acc += ps × (price of the last selected r)
  if fs < 0: return 0
  return max(acc, 0) + flat(peak)

  select(fs, ov, next): if fs ≤ 0 → first range
      u = fs (ov = 0) | fs − ov + 1 (ov > 0) | fs + ov (ov < 0)
      for each range r in order: if u = r.to and next > 0 → the following range; if u = r.to → r;
                                 if u ≥ r.from and (r.to = null or u < r.to) → r
      otherwise the first range
  ```
- **BE-PR-36** `flat(peak)`: add the ranges' flat amounts in order and stop after the first range whose `to_value` is null or `≥ peak`. Flat amounts follow the **peak** full units reached in the period, not the final count (a temporary spike into tier 2 bills tier 2's flat). [vec: pricing.prorated_graduated.001, pricing.prorated_graduated.003, pricing.prorated_graduated.005, pricing.prorated_graduated.006, pricing.prorated_graduated.007, pricing.prorated_graduated.008, pricing.prorated_graduated.009, pricing.prorated_graduated.010]
- **BE-PR-37** With `U ≠ 0` and empty per-event lists the reference fails. RBD-45 (corrected profile, proposed: amount 0). [vec: pricing.prorated_graduated.012, pricing.prorated_graduated.012x]
- **BE-PR-38** `unit_amount = amount / Σ full[i]`, 0 when that sum is 0; `amount_details = {}`. Compat vectors compare prorated amounts to 6 decimal places (binary-float coefficients). [vec: pricing.prorated_graduated.001, pricing.prorated_graduated.003, pricing.prorated_graduated.005, pricing.prorated_graduated.006, pricing.prorated_graduated.007, pricing.prorated_graduated.008, pricing.prorated_graduated.009, pricing.prorated_graduated.010]

## 10. Projections

- **BE-PR-39** Projected units (when projection is requested with a period ratio ρ): 0 when `U = 0` or `ρ ≤ 0`, else `round_half_away(U / ρ, 2)`. [vec: pricing.projection.001, pricing.projected.007]
- **BE-PR-40** Projected amount per model: standard = projected units × amount; package = `ceil((PU − free_units) / package_size) × amount` in exact decimal (0 when `PU − free_units ≤ 0`); graduated = re-price PU walking the ranges with capacities `to_value − units already priced` and adding the flat of every tier that receives units (0 when PU = 0); volume = PU × price + flat of the range matched by PU (BE-PR-23 with PU), 0 when none; percentage, graduated percentage, dynamic, custom and prorated graduated = `amount / ρ` (0 when the amount or ρ is 0); grouped = sums. [vec: pricing.projection.006, pricing.projection.008, pricing.projected.005, pricing.projected.006, pricing.projected.007]
- **BE-PR-41** Period ratio of the projected-usage API: `ρ = 1` when now ≥ the period end, `ρ = 0` when now < the period start, else `days(from, now) / days(from, to)` with chapter 01 day counting in the customer's time zone (BE-DM-15), clamped to [0, 1]. When ρ is not in (0, 1] the projection is 0. [vec: pricing.projection.001, pricing.projection.002, pricing.projection.003]
- **BE-PR-42** Projected fee values: recurring metrics project the current fee unchanged (amount cents and units); otherwise `projected_amount_cents = round_half_away(projected amount, e) × s` (0 when negative or absent) and projected units are floored at 0. [vec: pricing.projection.001, pricing.projection.004, pricing.projection.006, pricing.projection.008]

## 11. Pay in advance (one fee per event)

Inputs for one event of a pay-in-advance charge (chapter 04 section 5 produces them): `A` = the period total, `a` =
the units this event makes billable (for sums: the rise above the period's high-water mark, BE-AG-40), `C` = events
count, `P`/`p` = period and event precise amounts (dynamic), RT and per-event values, the cached high-water state.
Kit convention: for a stored event, `A` and `C` include it and it is the LAST per-event value; for an estimate they
exclude it and `event_value` (default `a`) is its value.

- **BE-PR-43** Stored event: `delta = price(A, C, P) − price(A − a, C − 1, P − p, flag exclude_event)`; both runs share RT and the per-event values; with `exclude_event` the current event's value is left out of the per-event values. [vec: pricing.in_advance.001, pricing.in_advance.004, pricing.in_advance.005, pricing.in_advance.007, pricing.in_advance.008, pricing.in_advance.010, pricing.in_advance.011, pricing.in_advance.014, pricing.in_advance.016, pricing.in_advance.017, pricing.in_advance.019, pricing.in_advance.020, pricing.in_advance.021, pricing.in_advance.022, pricing.in_advance.023, pricing.in_advance.024, pricing.in_advance.025, pricing.in_advance.026, pricing.in_advance.027, pricing.in_advance.027x, pricing.in_advance.028, pricing.in_advance.029, pricing.in_advance.030]
- **BE-PR-44** Estimate (event not stored): `delta = price(A + a, C + 1, P + p, flag include_event_value) − price(A, C, P)`; `include_event_value` appends the event's value to the per-event values. [vec: pricing.in_advance.002]
- **BE-PR-45** In-advance model map: standard, graduated (always the plain algorithm, never prorated graduated), graduated percentage, package, percentage, custom, dynamic. Volume has no in-advance algorithm (the reference fails; validation forbids it, BE-PR-79). [vec: pricing.in_advance.010, pricing.in_advance.011, pricing.in_advance.033, pricing.validate_charge.001]
- **BE-PR-46** `amount_cents = round_half_away(delta, e) × s`; `precise_amount_cents = delta × s` (unrounded); `unit_amount = 0` when the rounded delta is 0, else `round_half_away(delta, e) / units_shown`. [vec: pricing.in_advance.001, pricing.in_advance.002, pricing.in_advance.004]
- **BE-PR-47** `units_shown`: when the cached current total, maximum and applied units are all known and current ≤ maximum → `max(applied units, 0)`; else when the charge is prorated → FU; else `a`. [vec: pricing.in_advance.007, pricing.in_advance.008, pricing.in_advance.035, pricing.in_advance.036, pricing.in_advance.037]
- **BE-PR-48** Details only for a stored event and only for percentage and graduated percentage (others `{}`). Percentage: `units`, `free_units`, `paid_units`, `free_events`, `paid_events`, `fixed_fee_total_amount`, `min_max_adjustment_total_amount`, `per_unit_total_amount` are the decimal-string differences (with − without); `rate` and `fixed_fee_unit_amount` come from the "with" run; then `free_units = units − paid_units` (the baseline reuses running totals that include the event: RBD-50 keeps this). Graduated percentage: for every range of the "with" run, match the "without" range with the same bounds (zeros when absent): `flat_unit_amount`, `units` and `total_with_flat_amount` are differences and `per_unit_total_amount = round_half_away(Δtotal_with_flat / Δunits, 2)` (`"0.0"` when Δunits ≤ 0) — an average that **includes** the flat (RBD-51; corrected profile, proposed: Δ(units × rate / 100)). [vec: pricing.in_advance.014, pricing.in_advance.016, pricing.in_advance.017, pricing.in_advance.019, pricing.in_advance.020, pricing.in_advance.021, pricing.in_advance.022, pricing.in_advance.026, pricing.in_advance.027, pricing.in_advance.027x, pricing.in_advance.028, pricing.in_advance.031]
- **BE-PR-49** The in-advance fee: `amount_cents` and `precise_amount_cents` of BE-PR-46, `unit_amount_cents = unit_amount × s` truncated toward zero, `precise_unit_amount = unit_amount`, `units = total_aggregated_units = units_shown`, `events_count = 1`, `pay_in_advance = true`, details of BE-PR-48 (or `{}`); it is created even when its amount is 0, carries the event's transaction id and the event's group values (chapter 07 invoices it). [vec: pricing.in_advance.001]
- **BE-PR-50** A charge that is not pay in advance refuses the computation with error code `apply_charge_model_error`. [vec: pricing.in_advance.034]

## 12. From pricing result to fee

- **BE-PR-51** One fee per bucket: a charge without filters has one bucket; with filters, one fee per filter plus one for the events matching no filter (charge properties and grouping keys); with grouping, one fee per group of each bucket (BE-PR-5). [vec: pricing.grouped.001, pricing.grouped.003, pricing.grouped.004]
- **BE-PR-52** Negative result: when the units or the amount are negative, `amount`, `unit_amount`, `units` and FU become 0 before the money fields are computed; the details are kept as computed (they may show negative numbers). [vec: pricing.fee_money.008, pricing.fee_money.009, pricing.fee_money.010, pricing.graduated.010, pricing.standard.006]
- **BE-PR-53** `amount_cents = round_half_away(amount, e) × s`; `precise_amount_cents = amount × s` stored with 15 decimal places; `precise_unit_amount = unit_amount` stored with 15 decimal places. [vec: pricing.fee_money.001, pricing.fee_money.002, pricing.fee_money.003, pricing.fee_money.004, pricing.fee_money.006]
- **BE-PR-54** `unit_amount_cents = unit_amount × s` **truncated toward zero** (integer storage): 0.0125 EUR per unit is 1 cent and 0.0199 EUR is 1 cent, while `amount_cents` rounds half away (RBD-47 keeps this). [vec: pricing.fee_money.001, pricing.fee_money.002, pricing.fee_money.007]
- **BE-PR-55** Stored units: in current usage of a pay-in-advance or prorated charge → `current_usage_units`; else for a prorated charge → FU when present, else U; else U. `total_aggregated_units` = the aggregation's weighted-sum total when present, else the stored units. [vec: pricing.fee_money.011, pricing.fee_money.012, pricing.fee_money.013, pricing.fee_money.014]
- **BE-PR-56** A fee is kept when the context is the recurring billing of non-invoiceable in-advance charges, or units ≠ 0, or `amount_cents ≠ 0`, or `events_count ≠ 0`, or a manual adjustment exists for it, or it is or has a true-up fee. Current usage shows every bucket: a bucket that keeps no fee is shown with a zero fee priced from an empty aggregation (so a graduated bucket shows its first-tier flat, BE-PR-16), and filter buckets with zero units can be hidden on request. [vec: pricing.fee_money.008, pricing.fee_money.009, pricing.fee_money.015, pricing.fee_money.016]
- **BE-PR-57** The fee of a non-invoiceable charge carries the charge's `pay_in_advance` flag. [vec: pricing.fee_money.017]
- **BE-PR-58** Stored form of `amount_details`: decimal values are JSON strings with at least one fraction digit (`"100.0"`, `"0.0125"`), integers stay JSON integers (`from_value: 0`, `per_package_size: 10`, `free_events: 2`), values copied from the properties keep their JSON type (`to_value: 0.1`). Kit vectors compare these numerically (string or number); only text-compared paths are spelling-sensitive. [vec: pricing.percentage.010]

## 13. Charge minimum true-up

- **BE-PR-59** `min_amount_cents` (≥ 0) is set only with the premium licence (otherwise 0) and is refused on pay-in-advance charges (`not_compatible_with_pay_in_advance`). The true-up is computed on period invoices only (not current usage, not progressive-billing invoices). [vec: pricing.validate_charge.008]
- **BE-PR-60** `used` = Σ `amount_cents` of **all** fees of the charge in the period (all filters, the default bucket, all groups; pricing-unit cents when a pricing unit applies). `prorated_min = min_amount_cents / charges_duration_days × days` computed in **binary64**, where `days` is the chapter 01 day count of the charges window in the customer's time zone, one less for a subscription terminated by an upgrade (BE-DM-15..18). No fee when `used ≥ prorated_min`. RBD-52 (corrected profile, proposed: exact decimal). [vec: pricing.true_up.001, pricing.true_up.002, pricing.true_up.002x, pricing.true_up.003, pricing.true_up.006, pricing.true_up.006x, pricing.true_up.008]
- **BE-PR-61** Otherwise a true-up fee is added, a copy of the bucket fee without a filter (the default bucket or the first group): `amount_cents = round_half_away(prorated_min − used)` (in binary64), `precise_amount_cents = dec(prorated_min) − used_precise` (dec = BE-PR-85 conversion), `unit_amount_cents = amount_cents`, `precise_unit_amount = precise_amount_cents / s`, `units = 1`, `total_aggregated_units = 1`, `events_count = 0`, no filter, linked to its parent fee. [vec: pricing.true_up.001, pricing.true_up.002, pricing.true_up.002x, pricing.true_up.009]
- **BE-PR-62** With a pricing unit, the differences are converted like a fee: pricing-unit amount `(prorated_min − used) / 100`, unit amount `(prorated_min − used_precise) / 100`, then BE-PR-63; the true-up fee carries the fiat fields and the pricing-unit record. [vec: pricing.true_up.007]

## 14. Pricing units (premium)

A charge may carry one pricing unit (code, short name, `conversion_rate` > 0 fiat per pricing unit). Its property
amounts and `min_amount_cents` are then in pricing units; the pricing-unit exponent is always 2.

- **BE-PR-63** Conversion of a charge result (amount A and unit amount u, in pricing units): pricing-unit record `amount_cents = round_half_away(A, 2) × 100`, `precise_amount_cents = A × 100`, `unit_amount_cents = trunc(u × 100)`, `precise_unit_amount = u`; fiat: `adj = pu_amount_cents × rate / 100`, `adj_u = pu_unit_amount_cents × rate / 100`, fiat `amount_cents = round_half_away(adj, e) × s`, `precise_amount_cents = adj × s`, `unit_amount_cents = adj_u × s` (truncated by the fee, BE-PR-54), `precise_unit_amount = adj_u`. The fiat values derive from the **rounded** pricing-unit cents (two roundings; RBD-46, corrected profile proposed: one rounding from A × rate). [vec: pricing.pricing_unit.001, pricing.pricing_unit.002, pricing.pricing_unit.002x, pricing.pricing_unit.003, pricing.pricing_unit.003x, pricing.pricing_unit.006, pricing.pricing_unit.007]
- **BE-PR-64** A fee of a charge with a pricing unit takes the fiat values as its money fields and keeps the pricing-unit record (amounts, unit amounts, conversion rate, short name). [vec: pricing.fee_money.020]
- **BE-PR-65** In advance, the pricing-unit amount is the in-advance `amount_cents` (already rounded to the PLAN currency and scaled by the plan subunit) divided by 100, and the unit amount is the plan-rounded unit amount: on a JPY plan 12.345 units at rate 1 become 0.12 pricing units, a 0-yen fee with a 12-yen unit amount (RBD-46; corrected profile, proposed: 12 yen). [vec: pricing.in_advance.038, pricing.in_advance.038x, pricing.in_advance.039, pricing.in_advance.039x]

## 15. Fixed charges

A fixed charge bills an add-on per subscription with a number of units: models `standard`, `graduated`, `volume`;
flags `pay_in_advance`, `prorated`; `units ≥ 0`; per-subscription unit overrides.

- **BE-PR-66** Constraints: volume cannot be paid in advance (`invalid_charge_model` on `pay_in_advance`); prorated graduated cannot be paid in advance (`invalid_charge_model` on `prorated`); negative units are refused (`value_is_out_of_range`); properties are validated and sliced like charges (amount / ranges and grouping keys only). [vec: pricing.validate_charge.022, pricing.validate_charge.023, pricing.validate_properties.051, pricing.filter_properties.006]
- **BE-PR-67** Unit events: creating or updating a fixed charge (or a subscription override) records a unit event `{units, timestamp}` for each active or incomplete subscription without an override; the timestamp is now when the change applies immediately (and the subscription is not incomplete), otherwise the start of the next billing period. [vec: scn.fixed_charge.override.001, scn.fixed_charge.units.001, scn.subscription.upgrade.001]
- **BE-PR-68** Units without proration: take the fixed charge's unit events of the subscription with timestamp in `[from, to)` plus the last-**created** event with timestamp before `from`; units = the units of the last-created of them (creation order decides, not timestamps); FU = the same; no event → 0. [vec: pricing.fixed_charge_units.001, pricing.fixed_charge_units.004, pricing.fixed_charge_units.005]
- **BE-PR-69** Units with proration: same event set ordered by creation; an event is dropped when a later-created event has an earlier timestamp. Each remaining event contributes `max(0, round_half_away(days / duration × units, 6))` where `days = end − start` in customer-local calendar dates, `start` = local date of `max(timestamp, from)`, `end` = local date of the next event's timestamp (or of `from` when that is earlier than `from`), and for the last event the local date of `to + 1 day`. units = Σ contributions; FU = the last-created event's units; the per-event lists are `full = [FU]`, `prorated = [units]`. [vec: pricing.fixed_charge_units.006, pricing.fixed_charge_units.007, pricing.fixed_charge_units.008, pricing.fixed_charge_units.009, pricing.fixed_charge_units.010]
- **BE-PR-70** Period-invoice fee (arrears, and in-advance fixed charges billed on the subscription invoice): for a pay-in-advance fixed charge the window is the fixed-charges period containing the invoice's billing timestamp (chapter 06), and nothing is billed when the invoice already holds a fee of this fixed charge or when a fee with units or amount > 0 for the same subscription and the same period (compared to the second) sits on an invoice that is neither voided nor deleted. The fixed charge's model prices the units of BE-PR-68/69 (a prorated graduated fixed charge uses prorated graduated with those one-element lists; prorated volume chooses the tier with FU); money as BE-PR-52..54 (the clamp also zeroes the total aggregated units); stored units = FU; kept when the context is recurring or units ≠ 0 or `amount_cents ≠ 0` or an adjustment exists. [vec: pricing.fixed_charge_fee.001, pricing.fixed_charge_fee.002, pricing.fixed_charge_fee.004, pricing.fixed_charge_fee.005, pricing.fixed_charge_fee.006, pricing.fixed_charge_units.010]
- **BE-PR-71** In-advance fee after a unit change: `delta = new units − units already billed in the current fixed-charges period`. `delta ≤ 0` → a zero fee (units 0, no refund). Otherwise the model prices `delta × coef` with `coef = (UTC date of period end − UTC date of the event + 1) / duration` in binary64 when prorated, else 1; `amount_cents = round_half_away(amount, e) × s`, `precise_amount_cents = amount × s`, `unit_amount_cents = round_half_away(amount_cents / delta)` (rounded, not truncated), `precise_unit_amount = amount / delta`, `units = delta`, details `{}`. The day count uses UTC calendar dates even for a customer in another zone (RBD-102; corrected profile, proposed: customer-local dates). [vec: pricing.fixed_charge_in_advance.001, pricing.fixed_charge_in_advance.002, pricing.fixed_charge_in_advance.002x, pricing.fixed_charge_in_advance.003, pricing.fixed_charge_in_advance.005, pricing.fixed_charge_in_advance.005x]
- **BE-PR-72** Upgrade credit for prorated in-advance fixed charges: when the fixed charge is pay in advance and prorated, the subscription has a previous subscription whose plan carries the matching fixed charge (same add-on), and the subscription has at most one non-deleted invoice, take `prev` = the latest-created fee of the previous plan's matching fixed charge whose fixed-charges period contains the current one (its start ≤ current start, its end ≥ current end); if there is one, the period-invoice fee (BE-PR-70) is reduced by `D = round_half_away(prev.amount_cents × cur_days / prev_days)` in binary64, with `cur_days = ceil((current end − current start) / 86 400 s)` and `prev_days = ceil((prev period end − prev fee timestamp) / 86 400 s)` (elapsed seconds, not calendar dates); `amount_cents −= D` and `precise_amount_cents −= D`, each floored at 0. [vec: scn.fixed_charge.upgrade_prorated.001]

## 16. Validation, defaults and slicing

- **BE-PR-73** Decimal parameters (`amount`, ranges' `per_unit_amount`/`flat_amount`, `rate`, `fixed_amount`, FA, per-transaction bounds) must be JSON **strings** that read as a finite decimal ≥ 0. The reader is permissive. Grammar: optional surrounding whitespace; an optional sign `+`/`-`; digits, where single underscores may separate digits (a trailing underscore is tolerated, a leading or doubled one is not); an optional fraction, with the dot allowed first (`.5`) or last (`5.`); an optional exponent `e`, `E`, `d` or `D` with an optional sign and at least one digit. `NaN` and `Infinity` parse but are not finite, so they are rejected; `-0` reads as 0 and passes; JSON numbers, `null`, hexadecimal, commas, embedded spaces and other text are rejected. [vec: pricing.standard.007, pricing.validate_properties.001, pricing.validate_properties.002, pricing.validate_properties.003, pricing.validate_properties.004, pricing.validate_properties.007, pricing.validate_properties.008, pricing.validate_properties.009, pricing.validate_properties.010, pricing.validate_properties.026, pricing.validate_properties.027, pricing.validate_properties.053, pricing.validate_properties.054, pricing.validate_properties.055, pricing.validate_properties.056]
- **BE-PR-74** Standard: `amount` → `invalid_amount`. Package: `amount` → `invalid_amount`; `package_size` must be a JSON integer > 0 → `invalid_package_size`; `free_units` must be a present JSON integer ≥ 0 → `invalid_free_units`. [vec: pricing.validate_properties.001, pricing.validate_properties.002, pricing.validate_properties.033, pricing.validate_properties.034, pricing.validate_properties.037]
- **BE-PR-75** Percentage: a `latest_agg` metric → `billable_metric: invalid_value`; `rate` → `invalid_rate`; optional `fixed_amount` → `invalid_fixed_amount`; optional FE must be an integer > 0 → `invalid_free_units_per_events`; optional FA (decimal string) → `invalid_free_units_per_total_aggregation`; with premium only: non-blank per-transaction bounds must be decimals (`invalid_amount` on the bound) and `min ≤ max` (`per_transaction_max_amount: per_transaction_max_lower_than_per_transaction_min`). [vec: pricing.validate_properties.038, pricing.validate_properties.039, pricing.validate_properties.041, pricing.validate_properties.042, pricing.validate_properties.043, pricing.validate_properties.044, pricing.validate_properties.045]
- **BE-PR-76** Ranges (graduated, volume, graduated percentage): empty or missing → `missing_<key>`. Per range: amounts → `invalid_amount` on `per_unit_amount`/`flat_amount` (graduated percentage: `flat_amount` → `invalid_amount`, `rate` → `invalid_rate`, and a `latest_agg` metric → `billable_metric: invalid_value`). Bounds: `next = 0` initially; each `from_value` must equal `next` or `next + 1`; every range but the last needs `to_value > from_value`, the last needs `to_value = null`; then `next = to_value` (graduated, graduated percentage) or `to_value + 1` (volume). A failure adds `invalid_<key>` (`invalid_graduated_ranges`, `invalid_volume_ranges`, `invalid_graduated_percentage_ranges`). So a graduated first range may start at 1, `[0,10],[10,…]` is valid for graduated but not volume, and volume accepts a skipped value (`[0,100],[102,…]`). [vec: pricing.validate_properties.016, pricing.validate_properties.017, pricing.validate_properties.018, pricing.validate_properties.019, pricing.validate_properties.020, pricing.validate_properties.021, pricing.validate_properties.022, pricing.validate_properties.023, pricing.validate_properties.025, pricing.validate_properties.026, pricing.validate_properties.027, pricing.validate_properties.028, pricing.validate_properties.029, pricing.validate_properties.030, pricing.validate_properties.031, pricing.validate_properties.032, pricing.validate_properties.047, pricing.validate_properties.050, pricing.validate_properties.051]
- **BE-PR-77** Grouping keys (all models): `pricing_group_keys` (or `grouped_by` when `pricing_group_keys` is absent) must be null, empty, or an array of non-empty strings → `invalid_type` on the key used. `presentation_group_keys`, when not blank: an array of objects with only `value` (non-empty string) and optional `options` (an object whose only key `display_in_invoice` is a boolean), else `invalid_type`; more than 2 entries → `too_many_keys`; duplicate values → `value_is_duplicated`. Dynamic and custom have no other property check. [vec: pricing.validate_properties.011, pricing.validate_properties.012, pricing.validate_properties.013, pricing.validate_properties.015]
- **BE-PR-78** Error surface: the validator reports `{field: [codes]}`; on the charge (or filter, or fixed charge) record every code is listed, in check order, under the single attribute `properties`, which is what the API returns (chapter 11). [vec: pricing.validate_properties.002, pricing.validate_properties.028]
- **BE-PR-79** Charge-level constraints (record validation; errors `{attribute: [code]}`): pay in advance is refused for volume and for metrics other than count, sum, unique count and custom (`pay_in_advance: invalid_aggregation_type_or_charge_model`); non-invoiceable requires pay in advance (`invoiceable: must_be_true_unless_pay_in_advance`); `regroup_paid_fees` requires pay in advance and non-invoiceable (`only_compatible_with_pay_in_advance_and_non_invoiceable`); a minimum with pay in advance → `min_amount_cents: not_compatible_with_pay_in_advance`, a negative minimum → `value_is_out_of_range`; prorated only for a recurring metric that is not a weighted sum, with standard in advance or standard/volume/graduated in arrears (`prorated: invalid_billable_metric_or_charge_model`); dynamic requires a sum metric and custom a custom metric (`charge_model: invalid_aggregation_type_or_charge_model`); graduated percentage requires premium (`charge_model: graduated_percentage_requires_premium_license`); an unknown model → `charge_model: value_is_invalid`. [vec: pricing.validate_charge.001, pricing.validate_charge.002, pricing.validate_charge.005, pricing.validate_charge.006, pricing.validate_charge.007, pricing.validate_charge.008, pricing.validate_charge.011, pricing.validate_charge.012, pricing.validate_charge.013, pricing.validate_charge.014, pricing.validate_charge.015, pricing.validate_charge.016, pricing.validate_charge.017, pricing.validate_charge.018, pricing.validate_charge.019, pricing.validate_charge.020, pricing.validate_charge.021]
Constraints matrix (a summary of BE-PR-66, BE-PR-75, BE-PR-76 and BE-PR-79; those rules are normative). "Pay in advance"
also needs a count, sum, unique-count or custom metric; "prorated" also needs a recurring metric that is not a weighted sum.

| Model | Charge: pay in advance | Charge: prorated, in arrears | Charge: prorated, in advance | Metric / licence | Fixed charge |
|---|---|---|---|---|---|
| `standard` | yes | yes | yes | — | yes (any timing, prorated or not) |
| `graduated` | yes | yes | no | — | yes; prorated only in arrears |
| `volume` | no | yes | no | — | yes; never in advance |
| `package` | yes | no | no | — | no |
| `percentage` | yes | no | no | not `latest_agg` | no |
| `graduated_percentage` | yes | no | no | not `latest_agg`; premium | no |
| `dynamic` | yes | no | no | `sum_agg` only | no |
| `custom` | yes | no | no | `custom_agg` only | no |

- **BE-PR-80** Fixed-charge constraints are those of BE-PR-66; the property rules of BE-PR-73..77 apply to fixed charges too. [vec: pricing.filter_properties.006, pricing.validate_charge.022, pricing.validate_charge.023, pricing.validate_properties.051]
- **BE-PR-81** A charge created without properties gets defaults: standard `{amount: "0"}`; graduated and volume one open range `{from 0, to null, per_unit "0", flat "0"}`; package `{package_size: 1, amount: "0", free_units: 0}`; percentage `{rate: "0"}`; graduated percentage one open range with rate, fixed and flat `"0"`; dynamic `{}`; custom none. [vec: pricing.default_properties.001, pricing.default_properties.002, pricing.default_properties.003, pricing.default_properties.005, pricing.default_properties.007, pricing.default_properties.008]
- **BE-PR-82** Before storage, properties are sliced to the keys of the model (standard `amount`; graduated `graduated_ranges`; volume `volume_ranges`; graduated percentage `graduated_percentage_ranges`; package `amount`, `free_units`, `package_size`; percentage `rate`, `fixed_amount`, `free_units_per_events`, `free_units_per_total_aggregation`, `per_transaction_min_amount`, `per_transaction_max_amount`; dynamic nothing) plus the non-blank grouping keys; `custom_properties` only for custom metrics (a JSON string is parsed; invalid JSON becomes `{}`). `grouped_by` becomes `pricing_group_keys` when the latter is blank, and empty keys are removed. Fixed charges keep only the standard/graduated/volume keys. [vec: pricing.simulate.005, pricing.filter_properties.001, pricing.filter_properties.004, pricing.filter_properties.005, pricing.filter_properties.006, pricing.filter_properties.007, pricing.filter_properties.008]

## 17. Instant estimates and the price simulator

- **BE-PR-83** Instant estimate of one event (pay-in-advance standard and percentage charges whose metric code is the event's; others are not estimated): units = the event's `field_name` property, or 1 when the metric has no field, after the metric expression (chapter 03) and the metric rounding; negative units → amount 0 (the units are reported unchanged); standard: `units × amount`; percentage: `units × rate / 100 + fixed_amount`, clamped to the optional per-transaction bounds (no premium check). Free units, packages and tiers are ignored (RBD-53 keeps this). `amount_cents = round_half_away(amount, e) × s` reported as a decimal; `precise_amount = amount`; the field named `precise_unit_amount` carries the unit amount in **minor** units (`round_half_away(amount, e) / units × s`, 0 when the rounded amount is 0); taxes 0; `events_count` 1. [vec: pricing.estimate_instant.001, pricing.estimate_instant.003, pricing.estimate_instant.005, pricing.estimate_instant.006, pricing.estimate_instant.007, pricing.estimate_instant.008]
- **BE-PR-84** Price simulator for a charge and N units: properties = the filter's, else the charge's when not empty, else the defaults, then sliced (BE-PR-82); the model prices an aggregation where U, FU, current and total units are N and RT is empty, whose event count reads as 10 (the simulated aggregation has no count of its own; a percentage fixed fee is therefore charged 10 times). Result: `charge_amount_cents` = the model amount in **major** units (unrounded, despite the name), `subscription_amount_cents` = the plan amount in cents, `total_amount_cents` = their sum. RBD-54 covers both quirks (corrected profile, proposed: `charge_amount_cents` in minor units, rounded to the currency; the event count of a simulation awaits the same ruling, so the count vector has no twin). [vec: pricing.simulate.001, pricing.simulate.001x, pricing.simulate.003, pricing.simulate.003x, pricing.simulate.004, pricing.simulate.004x, pricing.simulate.005, pricing.simulate.005x, pricing.simulate.006]

## 18. Number representation and premium gates

- **BE-PR-85** Binary-float islands (compat profile; RBD-96 umbrella, corrected profile proposed: exact decimals): package count (BE-PR-9), volume per-unit detail (BE-PR-25), graduated-percentage tier units with JSON-float bounds (BE-PR-19), prorated-graduated coefficients (BE-PR-35), true-up proration (BE-PR-60/61) and the fixed-charge in-advance coefficient (BE-PR-71). Where a binary64 value meets a decimal it is converted by taking its shortest round-trip decimal text and **truncating it to 16 significant digits** (30.499999999999996 → 30.49999999999999; 0.30000000000000004 → 0.3; 0.09999999999999998 stays). Vectors of these behaviours carry the tag `float-island`. [vec: pricing.true_up.002, pricing.true_up.002x, pricing.true_up.006, pricing.true_up.006x, pricing.fixed_charge_in_advance.002, pricing.fixed_charge_in_advance.002x, pricing.fixed_charge_in_advance.005, pricing.fixed_charge_in_advance.005x, pricing.gp.006, pricing.gp.006x, pricing.package.008, pricing.package.008x, pricing.prorated_graduated.001, pricing.volume.008]
- **BE-PR-86** Premium-gated pricing behaviour (RBD-97): the graduated percentage model (charge validation), per-transaction percentage bounds (pricing and validation), pricing units, charge minimums, and setting `invoiceable`/`regroup_paid_fees` at charge creation; target-wallet grouping additionally needs the organization feature. Vectors set `premium` explicitly. [vec: pricing.validate_charge.019, pricing.validate_charge.020]

## 19. Rebuild decisions touching pricing

| Topic | Decision | Behaviour at the pin (compat) | Corrected profile | Vectors |
|---|---|---|---|---|
| percentage free units | RBD-41 | per-transaction percentage frees FA across any number of events | proposed: BE-PR-27 semantics | pricing.percentage.016, pricing.percentage.016x |
| graduated percentage tiers | RBD-42 | graduated percentage ignores adjacency, binary-float bounds | proposed: adjacency rule, exact decimals | pricing.gp.006, pricing.gp.006x, pricing.gp.009, pricing.gp.009x |
| package count | RBD-43 | package count in binary64 | proposed: exact ceiling | pricing.package.008, pricing.package.008x |
| volume, negative units | RBD-44 | volume with negative units fails | proposed: amount 0 | pricing.volume.009, pricing.volume.009x |
| prorated graduated, no data | RBD-45 | prorated graduated with units and no per-event data fails | proposed: amount 0 | pricing.prorated_graduated.012, pricing.prorated_graduated.012x |
| pricing units | RBD-46 | pricing units round twice; in advance divides plan cents by 100 | proposed: one rounding from the precise amount | pricing.pricing_unit.002/003(x), pricing.in_advance.038/039(x) |
| unit amount cents | RBD-47 | `unit_amount_cents` truncated, `amount_cents` half away | KEEP | pricing.fee_money.001, pricing.fee_money.007 |
| zero-usage flat | RBD-48 | first-tier flat billed at zero usage | KEEP | pricing.graduated.001, pricing.gp.001, pricing.volume.001, pricing.fixed_charge_fee.006 |
| volume tier match | RBD-49 | volume tier by `ceil(N)` | KEEP | pricing.volume.003, pricing.volume.011 |
| in-advance baseline | RBD-50 | in-advance baseline reuses running totals incl. the event | KEEP | pricing.in_advance.014 … 022 |
| in-advance details | RBD-51 | in-advance graduated-percentage `per_unit_total_amount` includes the flat | proposed: Δ(units × rate / 100) | pricing.in_advance.027, pricing.in_advance.027x |
| true-up proration | RBD-52 | true-up proration in binary64 | proposed: exact decimal | pricing.true_up.002(x), pricing.true_up.006(x) |
| instant estimates | RBD-53 | instant estimates only standard/percentage, no free units | KEEP | pricing.estimate_instant.* |
| price simulator | RBD-54 | simulator `charge_amount_cents` in major units; the simulated event count reads as 10 | proposed: minor units (event count: owner) | pricing.simulate.001 … 005 (twins `…x`), pricing.simulate.006 (compat only) |
| fixed charge in advance | RBD-102 | fixed-charge in-advance proration counts UTC calendar dates | proposed: customer-local dates | pricing.fixed_charge_in_advance.005, pricing.fixed_charge_in_advance.005x |
| float islands | RBD-96 | float islands (BE-PR-85) | proposed: exact decimals | tag `float-island` |
| premium gates | RBD-97 | premium gates (BE-PR-86) | product scope (owner) | tag `premium` |

## 20. Edge cases

- Zero usage still bills the first tier's flat amount (graduated, graduated percentage, volume) and the fee is kept because its amount is not 0 (pricing.graduated.001, pricing.volume.001, pricing.fixed_charge_fee.006).
- Units exactly at a range's `to_value` stay in that range; one unit fraction above starts the next tier and pays its flat (pricing.graduated.002, pricing.graduated.003, pricing.graduated.009).
- Unsorted graduated ranges are not sorted: `[{11,∞},{0,10}]` count as adjacent (second `from` = first `to` read as 0) and price 12 units as 1 unit (pricing.graduated.011).
- Package `unit_amount` divides by paid units, not units (pricing.package.009).
- Percentage free units: per-event (first FE events) versus total (FA) — the smaller count of free events wins, and an event reaching FA exactly pays the fixed fee (pricing.percentage.012, pricing.percentage.013).
- Negative usage: standard and graduated return negative amounts that the fee clamps to 0; volume fails; package bills 0 (pricing.standard.006, pricing.graduated.010, pricing.volume.009, pricing.package.010).
- A fee clamped to zero is still kept when its bucket counted events (pricing.fee_money.009).
- Dynamic bills 0 whenever the units are 0, even if events carry amounts (pricing.dynamic.002).
- In-advance details use averages that include flats (graduated percentage) and recompute free units (percentage) (pricing.in_advance.027, pricing.in_advance.016).
- The price simulator charges a percentage fixed fee 10 times and returns its charge amount in major units (pricing.simulate.006, pricing.simulate.001).
- Instant estimates report `amount_cents` as a decimal and `precise_unit_amount` in minor units (pricing.estimate_instant.001, pricing.estimate_instant.008).
- Fixed-charge units follow creation order, not timestamps (pricing.fixed_charge_units.005, pricing.fixed_charge_units.009).

## 21. Vectors

| File | Op | Vectors | Notes |
|---|---|---|---|
| `pricing.models.jsonl` | `pricing.charge_model` | 106 | standard, package, graduated, gp (graduated percentage), volume, percentage, dynamic, custom, prorated_graduated, grouped, projected |
| `pricing.in_advance.jsonl` | `pricing.pay_in_advance` | 42 | delta pricing, sequences from the reference's end-to-end examples, pricing units in advance |
| `pricing.fees.jsonl` | `pricing.fee_money`, `pricing.true_up`, `pricing.pricing_unit` | 41 | fee money fields, persistence, true-up, conversions |
| `pricing.validation.jsonl` | `pricing.validate_properties`, `pricing.validate_charge`, `pricing.default_properties`, `pricing.filter_properties` | 96 | error codes; `errors` compared strictly |
| `pricing.fixed_charges.jsonl` | `pricing.fixed_charge_units`, `pricing.fixed_charge_fee`, `pricing.fixed_charge_in_advance` | 23 | unit events, prorated units, fees |
| `pricing.misc.jsonl` | `pricing.projection`, `pricing.estimate_instant`, `pricing.simulate` | 26 | projections, estimates, simulator |

Evidence: every `both`/`compat` vector is EXECUTED through the oracle adapter at the pin; corrected twins are
RECOMPUTED with exact decimal arithmetic (`ruling: proposed` until the owner rules). Run them with
`python3 reimplementation-kit/scripts/kitrun.py --impl-cmd "<adapter>" --areas pricing`.

## Provenance (maintainers)

Executed 2026-10-02 on the pinned toolchain (Ruby 4.0.6, database `lago_api_test_a5`): `oracle.sh run` over
`spec/services/charge_models`, `spec/services/charges/{apply_pay_in_advance_charge_model_service_spec.rb,pay_in_advance,validators,estimate_instant,calculate_price_service_spec.rb}`,
`spec/services/fees/{charge_service_spec.rb,create_true_up_service_spec.rb,fixed_charge_service_spec.rb,build_pay_in_advance_fixed_charge_service_spec.rb,create_pay_in_advance_service_spec.rb,estimate_instant,projection_service_spec.rb}`,
`spec/services/fixed_charge_events/aggregations` and `spec/models/{pricing_unit_usage,charge,fixed_charge,charge_filter,applied_pricing_unit}_spec.rb`
→ `{"example_count":894,"failure_count":0}`. Re-run in the fix round of 2026-10-02 (database `lago_api_test_fr5`):
kitrun of the pricing vectors against `oracle.sh adapter` → `pricing 315 PASS 0 FAIL` (every `both`/`compat` vector,
compat profile). The corrected twins (RBD-41..46, RBD-51, RBD-52, RBD-54, RBD-102, RBD-96) are RECOMPUTED with exact
decimal arithmetic. The oracle module is `reimplementation-kit/scripts/maintainer/oracle-adapter/ops/pricing.rb`.

| Rules | Reference code @591ae90 |
|---|---|
| BE-PR-1, BE-PR-4, BE-PR-5 | `$API/app/services/charge_models/base_service.rb:36-56`, `$API/app/services/charge_models/factory.rb:5-62`, `$API/app/services/charge_models/grouped_service.rb:18-40`, `$API/app/services/charge_models/pricing_structure.rb:30-50` |
| BE-PR-2 | `$API/app/services/fees/charge_service/sources/charge.rb:36-42`, `$API/app/services/fees/charge_service.rb:74-97` |
| BE-PR-6, BE-PR-7 | `$API/app/services/charge_models/standard_service.rb:7-20` |
| BE-PR-8..11 | `$API/app/services/charge_models/package_service.rb:7-70` |
| BE-PR-12..17 | `$API/app/services/charge_models/graduated_service.rb:8-69`, `$API/app/services/charge_models/amount_details/range_graduated_service.rb:13-66` |
| BE-PR-18..21 | `$API/app/services/charge_models/graduated_percentage_service.rb:8-42`, `$API/app/services/charge_models/amount_details/range_graduated_percentage_service.rb:12-64` |
| BE-PR-22..26 | `$API/app/services/charge_models/volume_service.rb:7-65` |
| BE-PR-27..32 | `$API/app/services/charge_models/percentage_service.rb:7-193` |
| BE-PR-33, BE-PR-34 | `$API/app/services/charge_models/dynamic_service.rb:7-35`, `$API/app/services/charge_models/custom_service.rb:7-23` |
| BE-PR-35..38 | `$API/app/services/charge_models/prorated_graduated_service.rb:11-169` |
| BE-PR-39..42 | `$API/app/services/charge_models/base_service.rb:69-78`, `$API/app/services/charge_models/graduated_service.rb:36-61`, `$API/app/services/charge_models/package_service.rb:16-26`, `$API/app/services/charge_models/volume_service.rb:15-28`, `$API/app/services/fees/projection_service.rb:28-108`, `$API/app/services/fees/projection_service.rb:157-166` |
| BE-PR-43..50 | `$API/app/services/charges/apply_pay_in_advance_charge_model_service.rb:15-157`, `$API/app/services/charges/pay_in_advance/amount_details_calculator.rb:8-62`, `$API/app/services/charge_models/factory.rb:64-83`, `$API/app/services/fees/create_pay_in_advance_service.rb:79-134` |
| BE-PR-51..58 | `$API/app/services/fees/charge_service.rb:74-136`, `$API/app/services/fees/charge_service.rb:253-355` |
| BE-PR-59..62 | `$API/app/services/fees/create_true_up_service.rb:16-80`, `$API/app/services/fees/charge_service.rb:43-45`, `$API/app/services/fees/charge_service.rb:385-398`, `$API/app/services/charges/create_service.rb:46-55`, `$API/app/models/charge.rb:152-156` |
| BE-PR-63..65 | `$API/app/models/pricing_unit_usage.rb:13-43`, `$API/app/models/pricing_unit.rb:16-22`, `$API/app/services/fees/create_pay_in_advance_service.rb:83-95` |
| BE-PR-66..72 | `$API/app/models/fixed_charge.rb:34-110`, `$API/app/services/fixed_charges/emit_events_service.rb:15-67`, `$API/app/services/fixed_charge_events/aggregations/base_service.rb:39-47`, `$API/app/services/fixed_charge_events/aggregations/simple_aggregation_service.rb:6-10`, `$API/app/services/fixed_charge_events/aggregations/prorated_aggregation_service.rb:8-154`, `$API/app/services/fees/fixed_charge_service.rb:77-222`, `$API/app/services/fees/build_pay_in_advance_fixed_charge_service.rb:18-188` |
| BE-PR-73..80 | `$API/app/services/validators/decimal_amount_service.rb:17-44`, `$API/app/services/validators/range_bounds_validator.rb:5-14`, `$API/app/services/charges/validators/base_service.rb:18-103`, `$API/app/services/charges/validators/package_service.rb:6-44`, `$API/app/services/charges/validators/percentage_service.rb:6-86`, `$API/app/models/concerns/charge_properties_validation.rb:6-25`, `$API/app/models/charge.rb:119-206` |
| BE-PR-81, BE-PR-82 | `$API/app/services/charge_models/build_default_properties_service.rb:10-85`, `$API/app/services/charge_models/filter_properties/base_service.rb:15-71`, `$API/app/services/charge_models/filter_properties/charge_service.rb:6-32` |
| BE-PR-83 | `$API/app/services/fees/estimate_instant/base_service.rb:18-97`, `$API/app/services/fees/estimate_instant/pay_in_advance_service.rb:38-46`, `$API/app/services/charges/estimate_instant/percentage_service.rb:14-28`, `$API/app/services/charges/estimate_instant/standard_service.rb:14-24` |
| BE-PR-84 | `$API/app/services/charges/calculate_price_service.rb:6-51` |
| BE-PR-85 | binary64 and conversion behaviour observed on the pinned runtime (bigdecimal 4.1.2): `Float − BigDecimal` and `BigDecimal(Float)` probes of 2026-10-02 |

Spec examples behind the vectors (all green on the pinned toolchain): `$API/spec/services/charge_models/*_spec.rb`
(standard :36/:52/:61, package :32/:48/:64, graduated :52-:289, graduated percentage :53-:220, volume :37-:182,
percentage :53-:338, prorated graduated :83-:379, dynamic :26/:34, custom :29, grouped :55/:107, factory :55/:155),
`$API/spec/services/charges/apply_pay_in_advance_charge_model_service_spec.rb:59-117`,
`$API/spec/scenarios/pay_in_advance_charges_spec.rb:609-1451` (sequences priced through the in-advance op),
`$API/spec/services/fees/charge_service_spec.rb:977-3306`, `$API/spec/services/fees/create_true_up_service_spec.rb:51-148`.
Each vector's `evidence.ref` names its example or `derived`. Update triggers: a pin bump (re-mint with the oracle), a
change of the bigdecimal gem or Ruby float formatting (BE-PR-85), a new charge model.
