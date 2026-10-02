# crc-6b: invoice totals and credit-note calculators (Python 3.12)

One adapter process for the areas `invoice` and `credit_notes` (JSON-lines adapter protocol v1).
Standard library only (`requirements.txt` is empty). Files: `adapter.py` (entry point, totals, taxes, coupons,
lifecycle, credit notes, void), `termination.py`, `commitment.py`, `periods.py`.

Adapter command, from the repository root:

    python3.12 impl/crc-6b/adapter.py

Grade:

    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "python3.12 impl/crc-6b/adapter.py" --areas invoice,credit_notes --profile compat

Both profiles (`compat`, `corrected`) are answered; binary64 islands use floats in compat and exact fractions in corrected.
