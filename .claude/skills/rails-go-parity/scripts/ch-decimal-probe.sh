#!/usr/bin/env bash
# ch-decimal-probe.sh — run the ClickHouse side of the Go<->Rails contract in clickhouse-local:
# how ClickHouse turns what events-processor (and Rails, and the connectors) send into stored
# columns. Every check carries an EXPECTED value (recorded 2026-10-01 on ClickHouse 26.2.9.9,
# the minor the dev compose image `clickhouse/clickhouse-server:26.2-alpine` pins).
#
# Usage (from anywhere; network needed on first run, ~210 MB download, Linux amd64/arm64):
#   .claude/skills/rails-go-parity/scripts/ch-decimal-probe.sh
#   .claude/skills/rails-go-parity/scripts/ch-decimal-probe.sh --version 25.8.9.20   # another CH release
#   .claude/skills/rails-go-parity/scripts/ch-decimal-probe.sh --bin /path/to/clickhouse
#   .claude/skills/rails-go-parity/scripts/run-probe.sh value -values-only | \
#     .claude/skills/rails-go-parity/scripts/ch-decimal-probe.sh -     # also map these Go values
#
# Sections:
#   D  decimal_value = toDecimal128OrZero(value, 26)       (events_enriched column default)
#   E  events_enriched_queue JSONEachRow parse of a Go EnrichedEvent + the MV expressions
#   L  events_dead_letter MV: timestamp COALESCE and ingested_at parse of Go FailedEvent.event
#   R  events_raw_queue/MV: timestamp and ingested_at forms sent by Rails and by connectors/*.yml
#
# Binary: ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/clickhouse-<version>/clickhouse
#         (downloaded from the ClickHouse GitHub release, only usr/bin/clickhouse is kept).
# Exit codes: 0 every check matched EXPECTED; 1 at least one MISMATCH (re-verify the contract
#             table for this CH version); 2 usage error / download or extraction failed.
# Read-only on the repo; works in a mktemp -d scratch dir.
set -euo pipefail

usage() { sed -n '2,25p' "$0"; }
V="${CH_VERSION:-26.2.9.9}" BIN="" STDIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) V="${2:?}"; shift 2 ;;
    --bin) BIN="${2:?}"; shift 2 ;;
    -) STDIN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ch-decimal-probe: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

CACHE="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
if [ -z "$BIN" ]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) arch=amd64 ;;
    Linux-aarch64|Linux-arm64) arch=arm64 ;;
    *) echo "ch-decimal-probe: no static build for $(uname -s)-$(uname -m); pass --bin <clickhouse>" >&2; exit 2 ;;
  esac
  dir="$CACHE/clickhouse-$V"
  BIN="$dir/clickhouse"
  if [ ! -x "$BIN" ]; then
    mkdir -p "$dir"
    tgz="$dir/ch.tgz"
    if [ ! -s "$tgz" ]; then
      url="https://github.com/ClickHouse/ClickHouse/releases/download/v${V}-stable/clickhouse-common-static-${V}-${arch}.tgz"
      echo "ch-decimal-probe: downloading $url" >&2
      curl -fsSL -o "$tgz.part" "$url" || {
        url="${url/-stable\//-lts\/}"; echo "ch-decimal-probe: retrying as LTS: $url" >&2
        curl -fsSL -o "$tgz.part" "$url"; } || { rm -f "$tgz.part"; echo "ch-decimal-probe: download failed" >&2; exit 2; }
      mv "$tgz.part" "$tgz"
    fi
    tar --no-same-owner -xzf "$tgz" -C "$dir" --strip-components=3 "clickhouse-common-static-${V}/usr/bin/clickhouse" || {
      echo "ch-decimal-probe: extraction failed" >&2; exit 2; }
    rm -f "$tgz"
  fi
fi
[ -x "$BIN" ] || { echo "ch-decimal-probe: $BIN is not executable" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/rgp-ch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$work"
chq() { "$BIN" local "$@"; }

echo "# ch-decimal-probe: ClickHouse $(chq --query 'SELECT version()') (default settings; production settings UNVERIFIED)"
miss=0
report() { # section input got expected
  local st=ok; [ "$3" = "$4" ] || { st=MISMATCH; miss=$((miss+1)); }
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$st"
}
printf 'sec\tinput\tgot\texpected\tstatus\n'

# ---- D: decimal_value. Inputs are the Go `value` strings value-format-probe prints, plus Rails forms.
D_CASES='999999|999999
1e+06|1000000
1000000|1000000
1.2345678e+07|12345678
1.2345675e+06|1234567.5
999999999999|999999999999
1000000000000|0
1e+12|0
1e+20|0
1e+21|0
9.007199254740992e+15|0
0.1|0.1
1e-07|0.0000001
<nil>|0
true|0
map[x:1]|0
12|12
2|2
-1e+06|-1000000
-1000000000000|0
|0'
while IFS='|' read -r v e; do
  got="$(chq --query "SELECT toString(toDecimal128OrZero('${v//\'/\\\'}', 26))")"
  report D "'$v'" "$got" "$e"
done <<<"$D_CASES"
if [ "$STDIN" = 1 ]; then
  while IFS= read -r v; do
    got="$(chq --query "SELECT toString(toDecimal128OrZero('${v//\'/\\\'}', 26))")"
    printf 'D+\t%s\t%s\t%s\t%s\n' "'$v'" "$got" "-" "n/a"
  done
fi

# ---- E: events_enriched_queue (columns of $API/db/clickhouse_migrate/20240705084952_*) + MV expressions
QS="organization_id String, external_subscription_id String, code String, timestamp String, transaction_id String, properties String, value Nullable(String), precise_total_amount_cents Nullable(Decimal(40,15))"
GOJSON='{"organization_id":"org","external_subscription_id":"sub","subscription_id":"","plan_id":"","transaction_id":"tx","code":"c","aggregation_type":"sum","properties":{"amount":1000000,"flag":true,"ratio":2,"nested":{"a":1},"n":null},"precise_total_amount_cents":"0.0","source":"http_ruby","value":"1e+06","timestamp":1741007009.123}'
out="$(echo "$GOJSON" | chq --structure "$QS" --input-format JSONEachRow --query \
  "SELECT toString(toDateTime64(timestamp, 3)), toString(JSONExtract(properties, 'Map(String, String)')), value, toString(toDecimal128OrZero(value, 26)), toString(precise_total_amount_cents) FROM table FORMAT TSVRaw")"
IFS=$'\t' read -r e_ts e_props e_val e_dec e_ptac <<<"$out"
report E "timestamp 1741007009.123 (JSON number)" "$e_ts" "2025-03-03 13:03:29.123"
report E "properties (numbers/bool/object/null)" "$e_props" "{'amount':'1000000','flag':'true','ratio':'2','nested':'{\"a\":1}','n':''}"
report E "value '1e+06' -> decimal_value" "$e_val -> $e_dec" "1e+06 -> 1000000"
report E "precise_total_amount_cents '0.0'" "$e_ptac" "0"
out="$(echo '{"organization_id":"o","external_subscription_id":"s","code":"c","timestamp":1,"transaction_id":"t","properties":{},"value":"1","precise_total_amount_cents":""}' | \
  chq --structure "$QS" --input-format JSONEachRow --query "SELECT toString(precise_total_amount_cents) FROM table FORMAT TSVRaw" 2>&1 | head -n1)"
report E "precise_total_amount_cents '' (Go zero value)" "$out" "0"

# ---- L: events_dead_letter MV (COALESCE from $API/db/clickhouse_migrate/20260430075848_update_events_dead_letter_mv.rb)
L_EXPR="COALESCE(toDateTime64OrNull(JSONExtractString(e, 'timestamp'), 3), toDateTime64(toFloat64OrNull(JSONExtractString(e, 'timestamp')), 3), toDateTime64(JSONExtractString(e, 'ingested_at'), 3))"
while IFS='|' read -r ev exp_ts exp_ing; do
  out="$(chq --query "SELECT toString($L_EXPR), toString(toDateTime64(JSONExtractString(e, 'ingested_at'), 3)) FROM (SELECT '$ev' AS e) FORMAT TSVRaw" 2>&1 | head -n1)"
  IFS=$'\t' read -r g_ts g_ing <<<"$out"
  report L "$ev" "ts=$g_ts ingested_at=${g_ing:-}" "ts=$exp_ts ingested_at=$exp_ing"
done <<'EOF'
{"timestamp":"1741007009.123","ingested_at":"2025-03-03T13:03:30"}|2025-03-03 13:03:29.123|2025-03-03 13:03:30.000
{"timestamp":1741007009.123,"ingested_at":"2025-03-03T13:03:30"}|2025-03-03 13:03:29.123|2025-03-03 13:03:30.000
{"timestamp":"2025-03-03T13:03:29.123Z","ingested_at":"2025-03-03T13:03:30"}|2025-03-03 13:03:30.000|2025-03-03 13:03:30.000
{"timestamp":"2025-03-03T15:03:29+02:00","ingested_at":"2025-03-03T13:03:30"}|2025-03-03 13:03:30.000|2025-03-03 13:03:30.000
{"timestamp":"1741007009.123","ingested_at":null}|2025-03-03 13:03:29.123|1970-01-01 00:00:00.000
EOF

# ---- R: events_raw_queue column parse ($API/db/clickhouse_migrate/20231026124912_*) and MV toDateTime64(timestamp, 3)
while IFS='|' read -r ts exp; do
  got="$(chq --query "SELECT toString(toDateTime64OrNull('$ts', 3))")"
  report R "MV timestamp '$ts'" "$got" "$exp"
done <<'EOF'
1741007009.123|2025-03-03 13:03:29.123
1741007009.0|2025-03-03 13:03:29.000
2025-03-03T13:03:29.123Z|\N
2025-03-03T15:03:29.123+02:00|\N
EOF
err="$(chq --query "SELECT toDateTime64('2025-03-03T13:03:29.123Z', 3)" 2>&1 | grep -oE 'CANNOT_PARSE_TEXT' | head -n1 || true)"
report R "MV toDateTime64 (non-OrNull) on RFC3339 'Z'" "${err:-no error}" "CANNOT_PARSE_TEXT"
while IFS='|' read -r v exp; do
  got="$(echo "{\"i\":$v}" | chq --structure "i DateTime64(3)" --input-format JSONEachRow --query "SELECT toString(i) FROM table FORMAT TSVRaw" 2>&1 | head -n1)"
  report R "ingested_at JSON $v -> DateTime64(3)" "$got" "$exp"
done <<'EOF'
"2025-03-03T13:03:30.456"|2025-03-03 13:03:30.456
1741007010|1970-01-21 03:36:47.010
"1741007010"|2025-03-03 13:03:30.000
EOF

echo "summary: mismatches=$miss"
[ "$miss" -eq 0 ] || exit 1
