# KIT-GAPS

1. **days_between offset sign.** Question: BE-DM-15 writes `ceil((to − from + offset(from) − offset(to)) / 24h)`, but the op schema and the prose ("local wall-clock duration") imply `+ offset(to) − offset(from)`. Where: reference/01-domain-model.md BE-DM-15, schemas/ops/domain.days_between. Assumption: the wall-clock definition (`+ offset(to) − offset(from)`); it passes the DST vectors (Sydney April), the literal formula does not.
2. **Non-accepted currency in to_minor_units.** Not specified; I raise `value_is_invalid` on `currency`. currency_exponent returns exponent 2 / 100 with accepted=false (not graded).
3. **MRO in to_minor_units.** Exponent 1 is used (power-of-ten conversion); the spec says undefined.
4. **Sub-microsecond instants.** Fractions beyond 6 digits are truncated (Python datetime); no vector needs more.
5. **invoice_number when finalizing with a missing sequential id.** Not specified; the adapter fails with an internal error (graded ERROR).
