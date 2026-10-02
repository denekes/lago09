# crc-2b — Lago pricing engine (area `pricing`), Python 3.12, standard library only

One adapter process speaking the kit's JSON-lines adapter protocol (proto 1). Ops: `pricing.charge_model`,
`pay_in_advance`, `fee_money`, `true_up`, `pricing_unit`, `fixed_charge_units`, `fixed_charge_fee`,
`fixed_charge_in_advance`, `projection`, `estimate_instant`, `simulate`, `default_properties`, `filter_properties`,
`validate_properties`, `validate_charge`. Profiles `compat` and `corrected`.

Adapter command (from the repository root):

    python3.12 impl/crc-2b/adapter.py

Grade:

    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "python3.12 impl/crc-2b/adapter.py" --areas pricing --profile compat

No dependencies (`requirements.txt` is empty; needs the system tz database for `zoneinfo`). All numbers are exact
`Decimal`; binary64 islands (BE-PR-85) are reproduced explicitly in compat.
