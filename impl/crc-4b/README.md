# crc-4b — usage aggregation engine (area `aggregation`)

Python 3.12, standard library only (`requirements.txt` is empty). One adapter process speaking the kit's
JSON-lines protocol; implements ops `aggregation.aggregate`, `in_advance_units`, `current_usage_in_advance`,
`matching_and_ignored`, `select_events`, `event_filter`, `group_keys` for the relational (`pg`) and columnar (`ch`)
stores, profiles `compat` and `corrected`.

Adapter command (from the repository root):

    python3.12 impl/crc-4b/adapter.py

Grade:

    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "python3.12 impl/crc-4b/adapter.py" --areas aggregation --profile compat
