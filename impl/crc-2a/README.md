# crc-2a — pricing engine adapter (Python 3.12, standard library only)

Implements the `pricing.*` ops (charge models, pay-in-advance deltas, fee money, true-up, pricing units, fixed
charges, projections, estimates, simulator, validation, defaults, slicing) from billing-engine-spec chapter 05.

Adapter command, from the repository root:

    impl/crc-2a/run.sh

(equivalent to `cd impl/crc-2a && /usr/bin/python3.12 adapter.py`). Grade with:

    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "impl/crc-2a/run.sh" --areas pricing --profile compat

Files: `adapter.py` (protocol loop), `ops.py` (op handlers), `pricing_core.py` (models, fee money),
`validation.py` (property/charge validation, defaults, slicing), `currencies.py` (exponent table from the appendix).
Profiles `compat` and `corrected` are both declared.
