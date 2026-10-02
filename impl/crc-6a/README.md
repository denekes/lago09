# crc-6a — invoice totals and credit-note calculators (Python 3.12)

One adapter process speaking the kit's JSON-lines protocol (proto 1) for the areas `invoice` and `credit_notes`
(18 ops). Standard library only (`requirements.txt` is empty); it declares both profiles, `compat` and `corrected`.

Adapter command, from the repository root:

    python3.12 impl/crc-6a/adapter.py

Grade it:

    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py \
        --impl-cmd "python3.12 impl/crc-6a/adapter.py" --areas invoice,credit_notes --profile compat
    # for information:  ... --profile corrected

Files: `adapter.py` (protocol loop, op table), `common.py` (decimal / binary64 helpers), `invoice.py` (totals pipeline,
taxes, coupons, lifecycle dates, bounds), `coupons.py` (coupon create / apply), `credit_notes.py` (compute, estimate,
validate, termination), `voiding.py` (void), `commitment.py` (minimum-commitment true-up with a small billing-run
simulator), `periods.py` (period algebra). Exact decimals everywhere; binary64 islands (RBD-68) only where the spec says
so, selected by the call's profile (`compat` = float islands, `corrected` = exact).
