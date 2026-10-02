# KIT-GAPS (crc-7)

1. **Q:** `wallets.interval_due` target method: which ongoing balance is used for the paid amount (the op input has none)?
   **Looked:** 09-wallets BE-WL-30/31, schema. **Assumed:** ongoing = 0 (target amount = full target; limits ignored). Passed shipped vectors.
2. **Q:** `progressive.check_thresholds` `attach: parent_plan` with `plan_fixed_cents`: precedence?
   **Looked:** BE-PB-5. **Assumed:** thresholds on the plan (plan_fixed_cents) replace the parent's; otherwise the parent's `fixed_cents`/`recurring_cents` apply.
3. **Q:** Does a wallet `consumption` with `inbound_id` unknown have an error code? **Looked:** BE-WL-14. **Assumed:** `wallet_transaction_not_found` (not graded).
4. **Q:** Draft/progressive fees in the ongoing balance: does `pay_in_advance` apply to them? **Looked:** BE-WL-50. **Assumed:** only to current-usage fees, as the text says.
5. **Q:** Corrected-profile twins (RBD-77, RBD-78) are not implemented: they are `proposed`/UNRULED and the corrected profile behaves as compat for them.
