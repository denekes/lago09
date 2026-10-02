# crc-5 — billing-period calculator (area `periods`)

Python 3.12, standard library only (`zoneinfo` needs the system tz database). `periods.py` holds the logic
(boundaries, invoice boundaries, billing days, periodic selection, chains, single-day price, subscription fee,
trial, termination credit days, plan-change classification, creation status, termination); `adapter.py` is the
JSON-lines adapter (proto 1, profiles `compat` and `corrected`).

Adapter command, from the repository root:

    python3.12 impl/crc-5/adapter.py

Grade:

    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "python3.12 impl/crc-5/adapter.py" --areas periods --profile compat
