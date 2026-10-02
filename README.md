# Lago re-implementation kit — clean-room pack v1 (2026-10-02)

This branch contains ONLY the clean-room pack of the re-implementation kit:

- `.claude/skills/reimplementation-kit/` — method, vector format, adapter protocol, `kitrun.py`, grading
- `.claude/skills/events-processor-spec/` — events-processor behaviour spec and conformance suite
- `.claude/skills/billing-engine-spec/` — billing-engine behaviour spec, unit vectors and scenarios

Start with `.claude/skills/reimplementation-kit/SKILL.md`.

Rules for implementers (clean room):

- Implement from this kit only. Do not fetch other branches, clone other repositories, or search the
  web for Lago, getlago or lago-api source. Installing open-source packages from PyPI or the Go proxy is fine.
- Do not embed vector ids or expected values in code, and never build lookup tables from `expected`.
- Log every question the kit does not answer in `KIT-GAPS.md` (question, where you looked, your assumption).
- Put your code under `impl/<component-id>/` with a `requirements.txt` and an adapter entry point, and a
  `REPORT.md` with your final kitrun / run-suite summary lines.

Pack built by `kit-pack.sh --cleanroom` from kit commit 577b18d (files=400, forbidden=0).
