# crc-1: domain primitives adapter (Python 3.12, stdlib only)

Money, time-zone, day counting and numbering primitives (area `domain`, 17 ops) behind the kit's JSON-lines adapter protocol.

Adapter command (from the repository root):

    python3.12 impl/crc-1/adapter.py

Grade:

    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "python3.12 impl/crc-1/adapter.py" --areas domain --profile compat

Files: `adapter.py` (ops), `currencies.py` (table generated from billing spec appendix-currencies.md). The loop reuses the kit's `scripts/adapter_ref.py`.
