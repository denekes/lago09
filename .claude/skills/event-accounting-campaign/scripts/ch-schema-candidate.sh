#!/usr/bin/env bash
# ch-schema-candidate.sh — prove the Phase-2 ClickHouse schema CANDIDATE on the value corpus with
# `clickhouse local` (no server, no Docker), against Postgres numeric(40,15) as the reference
# (DECIDED OD-3 (owner, 2026-10-02): a ClickHouse schema change is acceptable).
#
# Compares, per value:
#   today     events_enriched.decimal_value as created today: Decimal(38,26)
#             DEFAULT toDecimal128OrZero(value, 26), fed with TODAY's Go string (go_value)
#   cand      CANDIDATE column Nullable(Decimal(40,15)) DEFAULT <expr below>, fed with the
#             CANDIDATE faithful Go string (corpus.tsv want_value; n/a rows keep today's text)
#   rederive  the same <expr> applied to TODAY's stored string, '<nil>' mapped to '0' first
#             (= a mutation re-deriving historical decimal_value from the stored `value`)
#   pg        the Rails decimal (corpus.tsv want_decimal) stored as Postgres numeric(40,15), the
#             type of lago-api enriched_events.decimal_value ($API/db/structure.sql:3059);
#             OVERFLOW where Postgres rejects it (|x| >= 1e25)
#   <expr> = if(abs(toDecimal256OrNull(value, 18)) < 1e25, round(toDecimal256OrNull(value, 18), 15), NULL)
#            (18 = 3 guard digits so that round() matches Postgres' half-away-from-zero rounding;
#             the explicit 1e25 bound is needed because a Decimal(40,15) column does not enforce
#             its precision: clickhouse local stores 1e30 in it unchanged)
# Plus 6 edge values that are not in the corpus (1e25 bound, rounding, beyond Decimal256).
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/event-accounting-campaign/scripts/ch-schema-candidate.sh [--no-pg] [--ch-bin PATH] [-q]
#     --no-pg   do not ask Postgres; the pg column is then computed by ClickHouse itself with the
#               same rounding rule (circular: no Postgres cross-check, say so in evidence)
#     --ch-bin  clickhouse binary (default: diagnostics-and-tooling ch-local.sh --path)
#     -q        print only the SUMMARY line
# Needs: go + the CGO env (via run.sh value-corpus, for today's Go strings); a clickhouse binary;
# psql + Postgres at DATABASE_URL (default postgres://lago:lago@localhost:5432/lago) unless --no-pg.
# Read-only: writes only to a mktemp dir (removed on exit); sends no data anywhere.
# Parses the whitespace-aligned value-corpus table: corpus values must not contain spaces.
#
# Exit codes: 0 table printed; 2 setup error (no clickhouse, value-corpus failed, psql missing
#             without --no-pg, parse error).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
use_pg=1 ch="" quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pg) use_pg=0 ;;
    --ch-bin) ch="${2:-}"; shift ;;
    -q) quiet=1 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "ch-schema-candidate: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
if [ -z "$ch" ]; then
  ch="$("$repo/.claude/skills/diagnostics-and-tooling/scripts/ch-local.sh" --path)" || { echo "ch-schema-candidate: no clickhouse binary (ch-local.sh --path failed)" >&2; exit 2; }
fi
[ -x "$ch" ] || { echo "ch-schema-candidate: not executable: $ch" >&2; exit 2; }
pgurl="${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}"
if [ "$use_pg" = 1 ]; then
  command -v psql >/dev/null 2>&1 || { echo "ch-schema-candidate: psql not found (use --no-pg)" >&2; exit 2; }
  psql "$pgurl" -XAtqc 'select 1' >/dev/null 2>&1 || { echo "ch-schema-candidate: Postgres unreachable (use --no-pg, or build-and-env)" >&2; exit 2; }
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/eac-chschema.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# 1. today's Go strings from the REAL enrichment code
if ! "$here/run.sh" value-corpus -mode value >"$tmp/vc.txt" 2>"$tmp/vc.err"; then
  echo "ch-schema-candidate: value-corpus failed:" >&2; tail -5 "$tmp/vc.err" >&2; exit 2
fi
awk 'started && NF==0 {exit} started && NF==7 {g=$4; if (g=="n/a") g=$3; print $1"\t"$3"\t"g"\t"$6}
     /^id +json +go_value +want_value/ {started=1}' "$tmp/vc.txt" >"$tmp/rows.tsv"
n_corpus="$(wc -l <"$tmp/rows.tsv")"
[ "$n_corpus" -gt 0 ] || { echo "ch-schema-candidate: could not parse the value-corpus table" >&2; exit 2; }

# 2. edge values (id, value used as go/want string, Rails decimal = the value itself)
while IFS='|' read -r id v; do printf '%s\t%s\t%s\t%s\n' "$id" "$v" "$v" "$v"; done >>"$tmp/rows.tsv" <<'EOF'
edge_max_40_15|9999999999999999999999999.999999999999999
edge_1e25|10000000000000000000000000
edge_neg_1e25|-1e25
edge_frac_19|0.1234567890123456789
edge_half_ulp|0.0000000000000005
edge_1e62|1e62
EOF

# 3. Postgres numeric(40,15) reference for the Rails decimal (psql -c does not interpolate
#    variables, so the statement goes through stdin)
: >"$tmp/pg.tsv"
while IFS=$'\t' read -r id _go _want dec; do
  if [ "$use_pg" = 1 ]; then
    if out="$(echo "select :'v'::numeric(40,15);" | psql "$pgurl" -XAtq -v ON_ERROR_STOP=1 -v v="$dec" 2>&1)"; then :
    elif printf '%s' "$out" | grep -q 'numeric field overflow'; then out=OVERFLOW
    else out=INVALID; fi
  else
    out=CH_SELF
  fi
  printf '%s\t%s\n' "$id" "$out" >>"$tmp/pg.tsv"
done <"$tmp/rows.tsv"

cand_expr="if(abs(toDecimal256OrNull(value, 18)) < toDecimal256('10000000000000000000000000', 0), round(toDecimal256OrNull(value, 18), 15), NULL)"
col() { echo "CREATE TABLE $1 (id String, value Nullable(String), decimal_value $2) ENGINE = Memory;"; }
cat >"$tmp/q.sql" <<EOF
CREATE TABLE r (id String, go_value String, want_value String, want_decimal String) ENGINE = Memory;
INSERT INTO r SELECT * FROM file('$tmp/rows.tsv', 'TabSeparated', 'id String, go_value String, want_value String, want_decimal String');
CREATE TABLE p (id String, pg String) ENGINE = Memory;
INSERT INTO p SELECT * FROM file('$tmp/pg.tsv', 'TabSeparated', 'id String, pg String');
$(col today "Nullable(Decimal(38, 26)) DEFAULT toDecimal128OrZero(value, 26)")
INSERT INTO today (id, value) SELECT id, go_value FROM r;
$(col cand "Nullable(Decimal(40, 15)) DEFAULT $cand_expr")
INSERT INTO cand (id, value) SELECT id, want_value FROM r;
$(col red "Nullable(Decimal(40, 15)) DEFAULT $cand_expr")
INSERT INTO red (id, value) SELECT id, if(go_value = '<nil>', '0', go_value) FROM r;
$(col selfpg "Nullable(Decimal(40, 15)) DEFAULT $cand_expr")
INSERT INTO selfpg (id, value) SELECT id, want_decimal FROM r;
CREATE TABLE v ENGINE = Memory AS
SELECT r.id AS id, r.go_value AS go_value, r.want_value AS want_value, r.want_decimal AS want_decimal,
       today.decimal_value AS today_dec, cand.decimal_value AS cand_dec, red.decimal_value AS rederive_dec,
       if(p.pg = 'CH_SELF', ifNull(toString(selfpg.decimal_value), 'OVERFLOW'), p.pg) AS pg,
       toDecimal256OrNull(pg, 15) AS pg_dec,
       (startsWith(r.id, 'edge_') = 0) AS in_corpus,
       if(pg IN ('OVERFLOW', 'INVALID'), cand_dec IS NULL, ifNull(cand_dec = pg_dec, 0)) AS cand_ok,
       if(pg IN ('OVERFLOW', 'INVALID'), rederive_dec IS NULL, ifNull(rederive_dec = pg_dec, 0)) AS rederive_ok,
       (cand_dec IS NULL AND ifNull(pg_dec = 0, 0)) AS policy_null,
       (rederive_dec IS NULL AND ifNull(pg_dec = 0, 0)) AS rederive_policy_null,
       ifNull(toDecimal256(today_dec, 26) = toDecimal256OrNull(r.want_decimal, 26), 0) AS today_ok
FROM r INNER JOIN today ON r.id = today.id INNER JOIN cand ON r.id = cand.id INNER JOIN red ON r.id = red.id
     INNER JOIN selfpg ON r.id = selfpg.id INNER JOIN p ON r.id = p.id;
EOF
if [ "$quiet" = 0 ]; then
  cat >>"$tmp/q.sql" <<'EOF'
SELECT id, go_value, want_value, today_dec AS today, cand_dec AS cand, rederive_dec AS rederive, pg,
       multiIf(cand_ok, 'OK', policy_null, 'POLICY_NULL', 'MISMATCH') AS cand_vs_pg,
       multiIf(rederive_ok, 'OK', rederive_policy_null, 'POLICY_NULL', 'NEEDS_RE_ENRICHMENT') AS rederive_vs_pg
FROM v ORDER BY in_corpus DESC, id FORMAT PrettyCompactMonoBlock;
EOF
fi
cat >>"$tmp/q.sql" <<'EOF'
SELECT concat('SUMMARY corpus_rows=', toString(countIf(in_corpus)),
  ' edge_rows=', toString(countIf(NOT in_corpus)),
  ' today_corpus_mismatches=', toString(countIf(in_corpus AND NOT today_ok)),
  ' cand_mismatches=', toString(countIf(NOT cand_ok AND NOT policy_null)),
  ' cand_policy_null=', toString(countIf(policy_null)),
  ' rederive_needs_re_enrichment=', toString(countIf(in_corpus AND NOT rederive_ok AND NOT rederive_policy_null)),
  ' rederive_policy_null=', toString(countIf(in_corpus AND rederive_policy_null)),
  ' pg_reference=PGREF') FROM v FORMAT TSVRaw;
EOF
ref=postgres; [ "$use_pg" = 1 ] || ref=none_circular
sed -i "s/PGREF/$ref/" "$tmp/q.sql"
if ! "$ch" local --multiquery --queries-file "$tmp/q.sql" </dev/null >"$tmp/out.txt" 2>"$tmp/ch.err"; then
  echo "ch-schema-candidate: clickhouse local failed:" >&2; tail -5 "$tmp/ch.err" >&2; exit 2
fi
ver="$("$ch" local --version </dev/null 2>/dev/null | sed -n 's/.*version \([0-9.]*\).*/\1/p' | head -1)"
if [ "$quiet" = 0 ]; then
  echo "== candidate column: decimal_value Nullable(Decimal(40, 15)) DEFAULT $cand_expr"
  echo "== ClickHouse $ver; pg = Rails decimal as Postgres numeric(40,15)$([ "$use_pg" = 1 ] && echo " ($(psql "$pgurl" -XAtqc 'show server_version' 2>/dev/null))" || echo " (--no-pg: computed by ClickHouse, circular)")"
fi
cat "$tmp/out.txt"
