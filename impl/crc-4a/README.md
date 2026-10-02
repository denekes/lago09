# crc-4a — usage aggregation engine (kit area `aggregation`)

Single-file adapter (`adapter.py`, Python 3.12, standard library only) speaking the kit's JSON-lines adapter protocol.
Ops: `aggregation.aggregate`, `in_advance_units`, `current_usage_in_advance`, `matching_and_ignored`, `select_events`,
`event_filter`, `group_keys`. Both stores (`pg` relational, `ch` columnar) and both profiles (`compat`, `corrected`:
columnar store takes relational semantics, exact proration decimals, RBD-35).

Adapter command (from the repository root):

    python3.12 impl/crc-4a/adapter.py

Grade:

    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "python3.12 impl/crc-4a/adapter.py" --areas aggregation --profile compat
