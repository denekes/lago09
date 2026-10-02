# REPORT (crc-6b)

Final kitrun results (shipped vectors, from repository root):

    profile compat:    SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=145 passed=145 skipped_ops=0 exit=0
      invoice 114/114 (100 %, core 100 %), credit_notes 31/31 (100 %, core 100 %)
    profile corrected: SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=145 passed=139 skipped_ops=0 exit=0
      invoice 111 pass + 3 unruled, credit_notes 28 pass + 3 unruled (all six corrected twins PASS)

Thresholds (invoice, credit_notes >= 95 %, core 100 %) are met in compat.

Time spent: about one session (reading ch. 07/08 and 06 excerpts, one implementation pass, one debugging pass).

Next steps: hidden vectors will probe the commitment simulator (advance plans, terminations, semiannual) and the
termination note with trials and coupons; I would add vectors-by-hand for those from BE-IV-54..56 / BE-SP-58..60,
review the float-island choices in KIT-GAPS 1 and 3, and split `adapter.py` into smaller modules.
