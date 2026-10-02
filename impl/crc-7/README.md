# crc-7: wallets, progressive billing, alerts

Python 3.12, standard library only. One adapter process for the areas `wallets`, `progressive`, `alerts`
(14 ops, profiles `compat` and `corrected`). It reuses the kit's `scripts/adapter_ref.py` protocol loop.

Adapter command (from the repository root):

    python3.12 impl/crc-7/adapter.py

Grade:

    python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "python3.12 impl/crc-7/adapter.py" --areas wallets,progressive,alerts --profile compat
