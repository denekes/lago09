# crc-3 — events + expression adapter (Python 3.12, standard library only)

One adapter process speaking the kit's JSON-lines protocol for areas `events` and `expression`
(profiles `compat` and `corrected`).

Files: `adapter.py` (protocol, expression op), `expr.py` (parser, exact decimals, number text),
`events.py` (timestamps, validation, batches, raw message).

Adapter command, from the repository root:

    python3.12 impl/crc-3/adapter.py

Grade:

    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "python3.12 impl/crc-3/adapter.py" --areas events,expression --profile compat
    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "python3.12 impl/crc-3/adapter.py" --areas events,expression --profile corrected
