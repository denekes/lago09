# KIT-GAPS (crc-5, periods)

1. **Zone-change window (BE-SP-23)** — "within 26 hours of C": direction/inclusivity not stated. Looked: ch. 06 §3. Assumed `abs(computed - C) <= 26 h`.
2. **Billing days with `utc_hour`** — the op schema says one run per UTC date at HH:10 UTC and the output lists UTC dates; whether only the predicate (BE-SP-30..32) applies or also BE-SP-34 selection is not stated. Assumed predicate only, evaluated on the local date of the run instant.
3. **`periods.chain` extra bounds** — not stated whether charges bounds are listed for every period; output them for all (expected is a subset).
4. **Fee gate output** — when the gate rejects the fee, basis/amounts are still returned (the vectors do this); only `created` is false. Gate (d) of BE-SP-46 (advance fixed charges) cannot be evaluated: no input carries fixed charges; ignored.
5. **"Fee created before this invoice" (BE-SP-39 full_period)** — assumed any `other_subscription_fees_created_at` strictly before `invoice_created_at`.
6. **Predecessor status after cancelling a pending successor** — `previous_subscription_status` is not defined in the chapter; the shipped vector shows `terminated`, emitted whenever a predecessor is given.
7. **Trial / `in_trial` without trial period** — assumed `trial_end_*` null and `in_trial` false.
8. **`create_status` pending case** — `started_at` null, no webhooks; BE-SP-50 start clamp applied to every creation, not only backdated ones.
9. **Corrected profile** — only the rulings visible in the twin vectors (RBD-55 exact fee, RBD-57/58 local dates, RBD-66 webhooks, RBD-103 termination test) are implemented; single-day price stays binary64 in both profiles because its vectors are `both`.
