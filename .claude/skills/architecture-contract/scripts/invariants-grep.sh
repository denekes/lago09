#!/usr/bin/env bash
set -euo pipefail
# invariants-grep.sh — static checks of the events-processor invariants that a grep can see.
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/architecture-contract/scripts/invariants-grep.sh [--quiet]
#
# What it checks (non-test Go files under events-processor/ only; read-only). Rule IDs N4/N5/N7 refer to
# the change-control skill's non-negotiables (change-control N4, N5, N7):
#   N4-cols    every gorm read selects an explicit column list (no implicit SELECT * via First/Find
#              without Select) — SELECT * + pgx cached plans => SQLSTATE 0A000 after a Rails DDL (9acd83e)
#   N4-org     every per-event query filters organization_id (global snapshot loaders are allowlisted)
#   N4-del     queries/snapshots on soft-deletable tables filter `deleted_at IS NULL`
#              (soft-deletable = billable_metrics, charges, billable_metric_filters, charge_filters,
#              charge_filter_values; subscriptions has no deleted_at in lago-api structure.sql)
#   N4-pin     each ApiStore query has an exact sqlmock pin (regexp.QuoteMeta) in a test   [WARN only]
#   N5-ctx     no struct in models/, processors/, config/kafka, config/redis stores a context.Context
#              (per-record side effects take the caller's ctx (the batch's context.Background()) as an
#              argument, never the process/signal ctx, 02a4bc8)
#   N7-guard   processRecordsAndCommit skips CommitRecords when findMaxCommitableRecord says !ok (9acd83e)
#   CONTRACT   Go-side snapshot of cross-repo / delivery constants (group name, keys, Redis ZSET,
#              bucket, retry horizon, poll size). A change is a C4 change: route via change-control.
#
# Output lines: "OK ...", "INFO ...", "WARN ...", "FLAG ..." (FLAG = rule violated or contract moved).
# Exit code: 0 = no FLAG, 1 = at least one FLAG (count in the SUMMARY line), 2 = setup error.
# Expected as of 2026-10-01 (code as of 5308258): exit 1, the single FLAG being
#   FLAG N4-cols events-processor/models/billable_metrics.go:61 FetchBillableMetric ...
# plus one WARN (N4-pin) for HasPayInAdvanceCharge (charges SQL is not pinned).

QUIET=0
case "${1:-}" in
  --quiet) QUIET=1 ;;
  -h|--help) awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not inside the lago git checkout" >&2; exit 2; }
EP="events-processor"
[ -d "$REPO/$EP" ] || { echo "$REPO/$EP not found" >&2; exit 2; }
cd "$REPO"

SOFT_DELETE_TABLES="billable_metrics charges billable_metric_filters charge_filters charge_filter_values"
OUT="$(mktemp)"; trap 'rm -f "$OUT" "$OUT.pin" "$OUT.tmp"' EXIT

go_files() { find "$EP/$1" -name '*.go' ! -name '*_test.go' 2>/dev/null | sort; }

# ---------- N4: gorm reads, function by function ----------
for f in $(go_files models) $(go_files cache) $(go_files processors); do
  awk -v file="$f" -v soft="$SOFT_DELETE_TABLES" '
    function tablefor(body,   t) {
      if (match(body, /Table\("[a-z_]+"\)/)) { t = substr(body, RSTART+7, RLENGTH-9); return t }
      if (body ~ /var [a-z]+ BillableMetric[^A-Za-z]/) return "billable_metrics"
      if (body ~ /var [a-z]+ Subscription[^A-Za-z]/)   return "subscriptions"
      if (body ~ /var [a-z]+ Charge[^A-Za-z]/)         return "charges"
      return "dynamic"
    }
    function analyze(   fname, t, issoft, n, arr, i, global) {
      fname = header
      sub(/^func (\([^)]*\) )?/, "", fname); sub(/[(\[].*/, "", fname)
      global = (fname ~ /^(StreamRows|GetAll)/)
      t = tablefor(body)
      if (body ~ /Select\(/) printf "OK   N4-cols %s:%d %s: explicit Select(...)\n", file, term, fname
      else printf "FLAG N4-cols %s:%d %s: gorm %s without Select(...) => implicit SELECT * (pgx cached-plan SQLSTATE 0A000 after DDL, cf. 9acd83e)\n", file, term, fname, termname
      if (body ~ /organization_id/) printf "OK   N4-org  %s:%d %s: filters organization_id\n", file, term, fname
      else if (global) printf "INFO N4-org  %s:%d %s: global snapshot query (cache warm-up), org filter not expected\n", file, term, fname
      else printf "FLAG N4-org  %s:%d %s: no organization_id filter\n", file, term, fname
      issoft = 0; n = split(soft, arr, " "); for (i = 1; i <= n; i++) if (arr[i] == t) issoft = 1
      if (t == "dynamic") printf "INFO N4-del  %s:%d %s: table chosen by caller (see StreamQueryConfig checks)\n", file, term, fname
      else if (!issoft) printf "OK   N4-del  %s:%d %s: table %s is not soft-deletable\n", file, term, fname, t
      else if (body ~ /deleted_at IS NULL/) printf "OK   N4-del  %s:%d %s: %s filtered by deleted_at IS NULL\n", file, term, fname, t
      else printf "FLAG N4-del  %s:%d %s: soft-deletable %s without deleted_at IS NULL\n", file, term, fname, t
      if (header ~ /\(store \*ApiStore\)/) printf "APISTORE %s %s %s:%d\n", fname, t, file, term
    }
    /^func / { infunc = 1; header = $0; body = ""; term = 0; termname = "" }
    infunc {
      body = body "\n" $0
      if (term == 0 && $0 !~ /ScanRows/ && match($0, /(^|[^A-Za-z])(First|Find|Take|Last|Rows|Pluck|Count|Raw|Exec)\(/)) {
        term = FNR; termname = substr($0, RSTART, RLENGTH); gsub(/[^A-Za-z]/, "", termname)
      }
    }
    /^}/ && infunc { if (term > 0 && body ~ /(Connection|Table\(|query)/) analyze(); infunc = 0 }
  ' "$f" >> "$OUT"
done

# ---------- N4-del for snapshot configs (StreamQueryConfig literals) ----------
for f in $(go_files models); do
  awk -v file="$f" -v soft="$SOFT_DELETE_TABLES" '
    /TableName:/ { if (match($0, /"[a-z_]+"/)) { t = substr($0, RSTART+1, RLENGTH-2); tl = FNR } }
    /WhereCondition:/ && t != "" {
      issoft = 0; n = split(soft, arr, " "); for (i = 1; i <= n; i++) if (arr[i] == t) issoft = 1
      if (!issoft) printf "OK   N4-del  %s:%d snapshot %s: not soft-deletable\n", file, FNR, t
      else if ($0 ~ /deleted_at IS NULL/) printf "OK   N4-del  %s:%d snapshot %s: deleted_at IS NULL\n", file, FNR, t
      else printf "FLAG N4-del  %s:%d snapshot %s: soft-deletable table without deleted_at IS NULL\n", file, FNR, t
      t = ""
    }
  ' "$f" >> "$OUT"
done

# ---------- N4-pin: exact sqlmock pins for ApiStore queries ----------
PINNED_TABLES="$(grep -h -A8 'regexp.QuoteMeta(`' $(find "$EP" -name '*_test.go') 2>/dev/null \
  | sed -n 's/.*FROM "\([a-z_]*\)".*/\1/p' | sort -u | tr '\n' ' ')"
while read -r tag fname table loc; do
  [ "$tag" = "APISTORE" ] || continue
  case " $PINNED_TABLES " in
    *" $table "*) echo "OK   N4-pin  $loc $fname: exact SQL pinned for \"$table\" (regexp.QuoteMeta in a _test.go)" ;;
    *) echo "WARN N4-pin  $loc $fname: no exact sqlmock pin for \"$table\" (only wildcard expectations)" ;;
  esac
done < <(grep '^APISTORE ' "$OUT") > "$OUT.pin"
grep -v '^APISTORE ' "$OUT" > "$OUT.tmp" || true
cat "$OUT.pin" >> "$OUT.tmp"; mv "$OUT.tmp" "$OUT"; rm -f "$OUT.pin"

# ---------- N5: context.Context stored in structs ----------
for f in $(go_files models) $(go_files processors) $(go_files config/kafka) $(go_files config/redis) $(go_files cache); do
  awk -v file="$f" '
    /^type [A-Za-z]+ struct \{/ { s = $2; ins = 1; next }
    ins && /^\}/ { ins = 0 }
    ins && /[ \t]context\.Context/ {
      if (file ~ /\/cache\// && (s == "Cache" || s == "CacheConfig")) printf "INFO N5-ctx  %s:%d struct %s carries the process ctx: lifetime of the CDC consumers (they must stop on shutdown), not per-record I/O\n", file, FNR, s
      else printf "FLAG N5-ctx  %s:%d struct %s stores a context.Context (side effects take the caller ctx = the batch Background ctx as an argument, never the process ctx, 02a4bc8)\n", file, FNR, s
    }
  ' "$f" >> "$OUT"
done
if grep -q 'func (store \*FlagStore) Flag(ctx context.Context' "$EP/models/stores.go"; then
  echo "OK   N5-ctx  $EP/models/stores.go:$(grep -n 'func (store \*FlagStore) Flag(' "$EP/models/stores.go" | cut -d: -f1) FlagStore.Flag takes the caller's ctx" >> "$OUT"
else
  echo "FLAG N5-ctx  $EP/models/stores.go FlagStore.Flag no longer takes ctx as its first argument" >> "$OUT"
fi

# ---------- N7: commit guard ----------
CF="$EP/config/kafka/consumer.go"
awk -v file="$CF" '
  /^func \(pc \*PartitionConsumer\) processRecordsAndCommit/ { inf = 1 }
  inf && /findMaxCommitableRecord\(/ && !fm { fm = FNR }
  inf && /if !ok/ && !guard { guard = FNR }
  inf && guard && !ret && /return/ { ret = FNR }
  inf && /CommitRecords\(/ && !cr { cr = FNR }
  inf && /^}/ { inf = 0 }
  END {
    if (fm && guard && ret && cr && fm < guard && guard < ret && ret < cr)
      printf "OK   N7-guard %s:%d processRecordsAndCommit returns before CommitRecords when no commitable prefix (9acd83e)\n", file, guard
    else
      printf "FLAG N7-guard %s processRecordsAndCommit: no `if !ok { return }` guard before CommitRecords (nil-record segfault, 9acd83e)\n", file
  }' "$CF" >> "$OUT"

# ---------- CONTRACT snapshot (C4: cross-repo / delivery constants) ----------
contract() { # rule file fixed-string description
  local rule="$1" file="$2" needle="$3" desc="$4" ln
  ln="$(grep -nF -- "$needle" "$EP/$file" | head -n1 | cut -d: -f1 || true)"
  if [ -n "$ln" ]; then echo "OK   $rule $EP/$file:$ln $desc"
  else echo "FLAG $rule $EP/$file $desc — expected text not found: $needle (contract moved? route via change-control)"; fi
}
{
  contract "CONTRACT" config/kafka/consumer.go 'fmt.Sprintf("%s_%s", cfg.ConsumerGroup, cfg.Topic)' 'consumer group id = <LAGO_KAFKA_CONSUMER_GROUP>_<raw topic>'
  contract "CONTRACT" processors/events_processor/event_producer_service.go 'fmt.Sprintf("%s-%s", event.OrganizationID, event.TransactionID)' 'enriched / in-advance key = <organization_id>-<transaction_id>'
  contract "CONTRACT" processors/main_processor.go 'initFlagStore(ctx, "subscription_refreshed_v2")' 'Redis ZSET key subscription_refreshed_v2'
  contract "CONTRACT" models/stores.go 'SUBSCRIPTION_BUCKET_DURATION int64 = 10' 'ZSET member bucket = 10 s'
  contract "CONTRACT" models/stores.go 'fmt.Sprintf("%s|%d", value, bucket)' 'ZSET member = <value>|<bucket>'
  contract "CONTRACT" processors/events_processor/subscription_refresh_service.go 'fmt.Sprintf("%s:%s", event.OrganizationID, event.SubscriptionID)' 'ZSET value = <organization_id>:<subscription_id>'
  contract "CONTRACT" processors/events_processor/processor.go '12*time.Hour' 'retryable failures older than 12 h (ingested_at) go to the DLQ (OD-2)'
  contract "CONTRACT" config/kafka/consumer.go 'PollRecords(ctx, 10000)' 'poll size 10000 records'
  contract "CONTRACT" config/kafka/consumer.go 'kgo.BlockRebalanceOnPoll()' 'BlockRebalanceOnPoll on the raw-topic group'
  contract "CONTRACT" config/kafka/consumer.go 'kgo.DisableAutoCommit()' 'manual commits only'
} >> "$OUT"

if [ "$QUIET" -eq 1 ]; then grep -E '^(FLAG|WARN)' "$OUT" || true; else cat "$OUT"; fi
FLAGS="$(grep -c '^FLAG' "$OUT" || true)"
WARNS="$(grep -c '^WARN' "$OUT" || true)"
echo "SUMMARY flags=$FLAGS warns=$WARNS (expected 2026-10-01: flags=1 warns=1)"
[ "$FLAGS" -eq 0 ] || exit 1
