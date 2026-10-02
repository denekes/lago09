#!/usr/bin/env bash
# parity-constants.sh — static, read-only comparison of the constants and code shapes that
# events-processor (Go) and lago-api / ClickHouse (Rails) must agree on.
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/rails-go-parity/scripts/parity-constants.sh                # EP=working tree, API=pinned gitlink
#   .claude/skills/rails-go-parity/scripts/parity-constants.sh --api DIR      # compare against another lago-api tree
#                                                                             #   (e.g. the paired lago-api PR branch)
#   .claude/skills/rails-go-parity/scripts/parity-constants.sh --ep DIR       # another events-processor tree
#   .claude/skills/rails-go-parity/scripts/parity-constants.sh --network      # also diff lago-expression core + its
#                                                                             #   Cargo.lock deps (Go ref vs Rails gem ref;
#                                                                             #   clones into $LAGO_SKILLS_CACHE)
#   .claude/skills/rails-go-parity/scripts/parity-constants.sh -q             # print only FAIL/CHANGED lines + summary
#
# Line ids: P<n>[a-z] = row P<n> of reference/contract-table.md (e.g. P20b = row P20);
#   named ids (AGG, TOPIC, KEYS, KEYR, SCH1-SCH5, DRIFT, REPR, HIST, DLY, CHTS) are cited in
#   that table's Evidence column.
# Line states:
#   OK       both sides agree (a MATCH row of the contract table)
#   KNOWN    a documented divergence/drift is still exactly as documented (DIVERGE-*/drift rows)
#   INFO     one-sided fact printed for the reader (no comparison)
#   FAIL     a MATCH contract no longer holds  -> parity broken; do not merge (change-control N6)
#   CHANGED  a documented divergence changed shape -> re-verify and update the contract table
# Exit codes: 0 all OK/KNOWN/INFO; 1 at least one FAIL; 3 no FAIL but at least one CHANGED;
#             2 usage error or a source file is missing.
# Read-only: never writes into the repo. --network writes only under $LAGO_SKILLS_CACHE.
set -euo pipefail

usage() { sed -n '2,26p' "$0"; }
EP="" API="" NETWORK=0 QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --api) API="${2:?--api needs a dir}"; shift 2 ;;
    --ep) EP="${2:?--ep needs a dir}"; shift 2 ;;
    --network) NETWORK=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "parity-constants: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "parity-constants: run inside the lago repo" >&2; exit 2; }
EP="${EP:-$REPO/events-processor}"
if [ -z "$API" ]; then
  API="$("$REPO/.claude/skills/research-methodology/scripts/pinned-checkout.sh" api)" || {
    echo "parity-constants: pinned-checkout.sh api failed" >&2; exit 2; }
fi
CACHE="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"

nOK=0 nKNOWN=0 nINFO=0 nFAIL=0 nCHANGED=0
emit() { # state id message
  local st="$1" id="$2"; shift 2
  case "$st" in
    OK) nOK=$((nOK+1)) ;; KNOWN) nKNOWN=$((nKNOWN+1)) ;; INFO) nINFO=$((nINFO+1)) ;;
    FAIL) nFAIL=$((nFAIL+1)) ;; CHANGED) nCHANGED=$((nCHANGED+1)) ;;
  esac
  if [ "$QUIET" = 1 ] && { [ "$st" = OK ] || [ "$st" = KNOWN ] || [ "$st" = INFO ]; }; then return; fi
  printf '%-8s %-5s %s\n' "$st" "$id" "$*"
}

# file paths (relative names are what gets printed)
need() { [ -f "$1" ] || { echo "parity-constants: missing source file $1" >&2; exit 2; }; }
G() { need "$EP/$1"; echo "$EP/$1"; }
R() { need "$API/$1"; echo "$API/$1"; }
gl() { local p; p="$(sed "s#^$EP/#events-processor/#; s#^$API/#\$API/#" <<<"$1")"; echo "$p"; }

# where FILE ERE -> "path:line" of first match (empty if none)
where() { local n; n="$(grep -nE -m1 -- "$2" "$1" 2>/dev/null | cut -d: -f1 || true)"; [ -n "$n" ] && echo "$(gl "$1"):$n" || true; }
# has FILE ERE -> 0/1
has() { grep -qE -- "$2" "$1" 2>/dev/null; }
# val FILE ERE SED-EXPR -> first extracted value
val() { grep -E -m1 -- "$2" "$1" 2>/dev/null | sed -E "$3" || true; }

eqcheck() { # id desc goval gowhere railsval railswhere
  if [ -n "$3" ] && [ "$3" = "$5" ]; then emit OK "$1" "$2: go=$3 ($4) rails=$5 ($6)"
  else emit FAIL "$1" "$2: go='${3}' (${4:-not found}) rails='${5}' (${6:-not found})"; fi
}
allhave() { # id state-if-all state-if-not desc  file1 ere1 [file2 ere2 ...]
  local id="$1" yes="$2" no="$3" desc="$4"; shift 4
  local locs="" missing=""
  while [ $# -gt 0 ]; do
    if has "$1" "$2"; then locs+="$(where "$1" "$2") "; else missing+="$(gl "$1") /$2/ "; fi
    shift 2
  done
  if [ -z "$missing" ]; then emit "$yes" "$id" "$desc [${locs% }]"
  else emit "$no" "$id" "$desc -- not found: ${missing% }"; fi
}
nonehave() { # id state-if-absent state-if-present desc file ere
  if has "$5" "$6"; then emit "$3" "$1" "$4 -- now present at $(where "$5" "$6")"
  else emit "$2" "$1" "$4 [absent from $(gl "$5")]"; fi
}

MAINP="$(G processors/main_processor.go)"; STORES="$(G models/stores.go)"; EVENTGO="$(G models/event.go)"
SUBSGO="$(G models/subscriptions.go)"; CSUBS="$(G cache/subscriptions.go)"; BMGO="$(G models/billable_metrics.go)"
CHGGO="$(G models/charges.go)"; ENRICH="$(G processors/events_processor/enrichment_service.go)"
REFRESH="$(G processors/events_processor/subscription_refresh_service.go)"
PRODUCER="$(G processors/events_processor/event_producer_service.go)"; TIMEGO="$(G utils/time.go)"
DOCKERF="$(G Dockerfile)"

KPS="$(R app/services/events/kafka_producer_service.rb)"; PPS="$(R app/services/events/post_process_service.rb)"
COMMON="$(R app/models/events/common.rb)"; CFACT="$(R app/services/events/common_factory.rb)"
CSRQ="$(R app/services/subscriptions/consume_subscription_refreshed_queue_service.rb)"; CLOCK="$(R clock.rb)"
BMRB="$(R app/models/billable_metric.rb)"; ENRB="$(R app/services/events/enrich_service.rb)"
CALC="$(R app/services/events/calculate_expression_service.rb)"; CREATE="$(R app/services/events/create_service.rb)"
UCQ="$(R app/services/events/stores/clickhouse/unique_count_query.rb)"
REENR="$(R app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb)"
KARAFKA="$(R karafka.rb)"; GEMFILE="$(R Gemfile)"; CHSTORE="$(R app/services/events/stores/clickhouse_store.rb)"
CHM="$API/db/clickhouse_migrate"
ENR_TBL="$(R db/clickhouse_migrate/20240705080709_create_events_enriched.rb)"
ENR_Q="$(R db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb)"
ENR_MV="$(R db/clickhouse_migrate/20240705085501_create_events_enriched_mv.rb)"
RAW_Q="$(R db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb)"
DLQ_Q="$(R db/clickhouse_migrate/20251110130723_create_events_dead_letter_queue.rb)"
DLQ_MV="$(find "$CHM" -maxdepth 1 -name '*events_dead_letter_mv*.rb' | sort | tail -n1)"; need "$DLQ_MV"
EXP_Q="$CHM/20250814124830_create_events_enriched_expanded_queue.rb"
CLOUD_ENR="$CHM/cloud/02_events_enriched.sql"

[ "$QUIET" = 1 ] || {
  echo "# parity-constants: EP=$(gl "$EP") (last EP commit $(git -C "$EP" log -1 --format='%h %cs' -- . 2>/dev/null || echo '?'))"
  echo "#                   API=\$API=$API ($(git -C "$API" log -1 --format='%h %cs' 2>/dev/null || echo '?'))"
}

# ---------------------------------------------------------------- P20/P21 Redis refresh protocol
gz="$(val "$MAINP" 'initFlagStore\(ctx, "' 's/.*initFlagStore\(ctx, "([^"]+)".*/\1/')"
rz="$(val "$CSRQ" 'REDIS_STORE_NAME = "' 's/.*REDIS_STORE_NAME = "([^"]+)".*/\1/')"
eqcheck P20a "redis ZSET name" "$gz" "$(where "$MAINP" 'initFlagStore\(ctx, "')" "$rz" "$(where "$CSRQ" 'REDIS_STORE_NAME = "')"
gb="$(val "$STORES" 'SUBSCRIPTION_BUCKET_DURATION int64 = ' 's/.*= *([0-9]+).*/\1/')"
rb="$(val "$CSRQ" 'SUBSCRIPTION_BUCKET_DURATION = ' 's/.*= *([0-9]+).*/\1/')"
eqcheck P20b "bucket seconds" "$gb" "$(where "$STORES" 'SUBSCRIPTION_BUCKET_DURATION int64 = ')" "$rb" "$(where "$CSRQ" 'SUBSCRIPTION_BUCKET_DURATION = ')"
allhave P20c OK FAIL "member '<org>:<sub>|<bucket>' written by Go, parsed by Rails as split('|').first.split(':').last" \
  "$REFRESH" 'fmt\.Sprintf\("%s:%s", event\.OrganizationID, event\.SubscriptionID\)' \
  "$STORES" 'fmt\.Sprintf\("%s\|%d", value, bucket\)' \
  "$CSRQ" 'value\.split\("\|"\)\.first\.split\(":"\)\.last'
allhave P20d OK FAIL "score = Go wall clock (unix s); Rails pops score <= now-bucket" \
  "$STORES" 'now := time\.Now\(\)\.Unix\(\)' "$STORES" 'Score: +float64\(now\)' \
  "$CSRQ" 'threshold = \(Time\.current - SUBSCRIPTION_BUCKET_DURATION\)\.to_i' \
  "$CSRQ" 'zrangebyscore\(REDIS_STORE_NAME, "-inf", threshold'
allhave P20e KNOWN CHANGED "doc drift: Rails comment says 'event timestamp as score' (Go uses processing time)" \
  "$CSRQ" 'using the event timestamp as score'
allhave P21 INFO CHANGED "Rails refresh clock runs every 10 s only if LAGO_REDIS_STORE_URL and LAGO_CLICKHOUSE_ENABLED are .present?" \
  "$CLOCK" 'ENV\["LAGO_REDIS_STORE_URL"\]\.present\? && ENV\["LAGO_CLICKHOUSE_ENABLED"\]\.present\?' \
  "$CLOCK" 'every\(10\.seconds, "schedule:refresh_flagged_subscriptions"\)' \
  "$MAINP" '"LAGO_REDIS_STORE_URL"'

# ---------------------------------------------------------------- P17/P18 source split
gs="$(val "$EVENTGO" 'HTTP_RUBY string = "' 's/.*= "([^"]+)".*/\1/')"
rs="$(val "$KPS" 'EVENT_SOURCE = "' 's/.*= "([^"]+)".*/\1/')"
eqcheck P17a "source marker" "$gs" "$(where "$EVENTGO" 'HTTP_RUBY string = ')" "$rs" "$(where "$KPS" 'EVENT_SOURCE = ')"
allhave P18 OK FAIL "api_post_processed = !clickhouse_events_store? (Rails) gates Go post-processing" \
  "$EVENTGO" 'json:"api_post_processed"' "$EVENTGO" 'func \(ev \*Event\) NotAPIPostProcessed\(\)' \
  "$KPS" 'api_post_processed: !organization\.clickhouse_events_store\?'
allhave P17b OK FAIL "expressions: Rails evaluates in API; Go only when source != http_ruby" \
  "$ENRICH" 'if enrichedEvent\.Source != models\.HTTP_RUBY' "$CREATE" 'CalculateExpressionService\.call\(organization:, event:\)'

# ---------------------------------------------------------------- aggregation enum
goagg="$(awk '
  /^type AggregationType int/ {t=1}
  t && /^const \(/ {c=1; i=0; next}
  c && /^\)/ {c=0}
  c { gsub(/[ \t]|=|iota/,""); if ($0!="") { if ($0!="_") idx[$0]=i; i++ } }
  /case AggregationType[A-Za-z]+:/ { n=$0; sub(/.*case /,"",n); sub(/:.*/,"",n); cur=n }
  cur && /aggType = "/ { s=$0; sub(/.*aggType = "/,"",s); sub(/".*/,"",s); name[cur]=s; cur="" }
  END { for (k in idx) print name[k] "=" idx[k] }' "$BMGO" | sort | tr '\n' ' ')"
railsagg="$(awk '/AGGREGATION_TYPES = \{/ {a=1; next} a && /\}\.freeze/ {a=0} a && $0 !~ /#/ && /_agg: [0-9]+/ {
  s=$0; gsub(/[ ,]/,"",s); sub(/_agg:/,"=",s); print s }' "$BMRB" | sort | tr '\n' ' ')"
eqcheck AGG "aggregation_type enum (name=int)" "${goagg% }" "$(where "$BMGO" 'AggregationTypeCount = iota')" "${railsagg% }" "$(where "$BMRB" 'AGGREGATION_TYPES = \{')"

# ---------------------------------------------------------------- P1-P3, P6-P8 subscription / BM resolution
allhave P1a OK FAIL "window started_at: date_trunc('millisecond', started_at::timestamp) <= ts" \
  "$SUBSGO" "date_trunc\('millisecond', subscriptions\.started_at::timestamp\) <= \?::timestamp" \
  "$PPS" "date_trunc\('millisecond', started_at::timestamp\) <= \?::timestamp" \
  "$COMMON" "date_trunc\('millisecond', started_at::timestamp\) <= \?::timestamp"
allhave P1b OK FAIL "window terminated_at: NULL or date_trunc('millisecond', terminated_at::timestamp) >= ts" \
  "$SUBSGO" "terminated_at IS NULL OR date_trunc\('millisecond', subscriptions\.terminated_at::timestamp\) >= \?" \
  "$PPS" "terminated_at IS NULL OR date_trunc\('millisecond', terminated_at::timestamp\) >= \?" \
  "$COMMON" "terminated_at IS NULL OR date_trunc\('millisecond', terminated_at::timestamp\) >= \?"
allhave P2 OK FAIL "ORDER BY terminated_at DESC NULLS FIRST, started_at DESC" \
  "$SUBSGO" 'Order\("terminated_at DESC NULLS FIRST, started_at DESC"\)' \
  "$PPS" 'order\("terminated_at DESC NULLS FIRST, started_at DESC"\)' \
  "$COMMON" 'order\("terminated_at DESC NULLS FIRST, started_at DESC"\)' \
  "$CSUBS" 'Simulates NULL FIRST for terminated_at'
allhave P3 KNOWN CHANGED "cache mode compares started_at at full precision (no ms truncation)" \
  "$CSUBS" 'if sub\.StartedAt\.Time\.After\(timestamp\) \{'
if has "$SUBSGO" 'status'; then emit CHANGED P6 "Go subscription lookup now mentions status at $(where "$SUBSGO" 'status') -- re-verify row P6"
elif has "$PPS" 'where\.not\(status: :incomplete\)'; then
  emit KNOWN P6 "status filter: Rails PostProcessService excludes incomplete [$(where "$PPS" 'where\.not\(status: :incomplete\)')]; Go has none [$(gl "$SUBSGO")]"
else emit CHANGED P6 "Rails PostProcessService no longer excludes incomplete -- re-verify row P6"; fi
allhave P7 KNOWN CHANGED "recurring fallback: Go re-runs the window at time.Now(); Rails uses .active.order(started_at: :desc)" \
  "$ENRICH" 'subResult = s\.fetchSubscription\(event, time\.Now\(\)\)' "$ENRICH" 'bm\.Recurring' \
  "$PPS" 'return @fallback_subscription = nil unless billable_metric&\.recurring' "$PPS" '\.active$'
allhave P8 OK FAIL "billable metric lookup on kept rows (org, code, deleted_at IS NULL)" \
  "$BMGO" 'organization_id = \? AND code = \? AND deleted_at IS NULL' "$BMRB" 'default_scope -> \{ kept \}'

# ---------------------------------------------------------------- P9-P12 value
allhave P9 OK FAIL "count -> value 1; others -> properties[field_name]" \
  "$ENRICH" 'enrichedEvent\.Value = utils\.StringPtr\("1"\)' "$ENRB" 'enriched_event\.value = 1 if billable_metric\.count_agg\?'
allhave P10a KNOWN CHANGED "value string = Go %v of the decoded JSON value (1e6 -> \"1e+06\", missing -> \"<nil>\")" \
  "$ENRICH" 'fmt\.Sprintf\("%v", enrichedEvent\.Properties\[bm\.FieldName\]\)' "$EVENTGO" 'Properties +map\[string\]any'
allhave P11 KNOWN CHANGED "CH decimal_value Decimal(38,26) DEFAULT toDecimal128OrZero(value, 26) (>=1e12 and '<nil>' -> 0)" \
  "$ENR_TBL" 'precision: 38, scale: 26, default: -> \{ "toDecimal128OrZero\(value, 26\)" \}' \
  "$CLOUD_ENR" 'Decimal\(38, 26\)\) DEFAULT toDecimal128OrZero\(value, 26\)'
allhave P12 KNOWN CHANGED "CH unique_count compares the raw value string" "$UCQ" 'arel_table\[:value\]\.as\("property"\)'
allhave P10b KNOWN CHANGED "Rails PG enrich defaults a missing property to 0 (Go emits \"<nil>\")" \
  "$ENRB" 'enriched_event\.value = \(event\.properties \|\| \{\}\)\[billable_metric\.field_name\] \|\| 0'

# ---------------------------------------------------------------- P14/P15 expression engine
gref="$(val "$DOCKERF" 'git checkout v[0-9]' 's/.*git checkout (v[0-9][0-9.]*).*/\1/')"
rref="$(val "$GEMFILE" 'gem "lago-expression"' 's/.*ref: "([^"]+)".*/\1/')"
emit INFO P14 "lago-expression: Go builds $gref ($(where "$DOCKERF" 'git checkout v[0-9]')), Rails gem ref $rref ($(where "$GEMFILE" 'gem "lago-expression"'))"
if [ "$NETWORK" = 1 ]; then
  lx="$CACHE/rails-go-parity/lago-expression.git"
  if [ ! -d "$lx" ]; then
    mkdir -p "$(dirname "$lx")"
    git clone -q --bare --filter=blob:none https://github.com/getlago/lago-expression "$lx" >&2
  else
    git -C "$lx" fetch -q --tags origin '+refs/heads/*:refs/heads/*' >&2 || true
  fi
  if git -C "$lx" diff --quiet "$gref" "$rref" -- expression-core 2>/dev/null; then
    emit OK P14n "expression-core identical between $gref and $rref (git diff --quiet -- expression-core)"
  else
    emit FAIL P14n "expression-core differs between $gref and $rref: git -C $lx diff --stat $gref $rref -- expression-core"
  fi
  # Identical core source can still link different crate versions: the workspace Cargo.lock decides.
  cdeps() { git -C "$lx" show "$1:Cargo.lock" 2>/dev/null | awk '
    /^name = "(bigdecimal|pest|serde_json)"$/ { n=$3; gsub(/"/,"",n); getline; v=$3; gsub(/"/,"",v); printf "%s=%s ", n, v }'; }
  gd="$(cdeps "$gref")"; rd="$(cdeps "$rref")"
  if [ -z "$gd" ] || [ -z "$rd" ]; then
    emit CHANGED P14d "could not read Cargo.lock at $gref or $rref in $lx -- re-verify row P14"
  elif [ "$gd" = "$rd" ]; then
    emit OK P14d "expression-core deps identical in Cargo.lock ($gref vs $rref): ${gd% }"
  else
    emit KNOWN P14d "expression-core deps differ in Cargo.lock: $gref ${gd% } vs $rref ${rd% } (behavioural equivalence untested)"
  fi
fi
allhave P15 KNOWN CHANGED "event.timestamp: Rails passes timestamp.to_i (int s); Go passes the float JSON timestamp" \
  "$CALC" 'Lago::Event\.new\(event\.code, event\.timestamp\.to_i' "$EVENTGO" 'Timestamp +float64 +`json:"timestamp"`'

# ---------------------------------------------------------------- P19 pay in advance
allhave P19 OK FAIL "in-advance pre-filter: any non-deleted pay_in_advance charge of the plan for the BM" \
  "$CHGGO" 'pay_in_advance IS TRUE AND deleted_at IS NULL' "$PPS" '\.pay_in_advance$' \
  "$KARAFKA" 'ENV\["LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC"\]'

# ---------------------------------------------------------------- P22/P23 time formats
allhave P22 OK FAIL "Rails sends timestamp as to_f.to_s / strftime(%s.%3N) and ingested_at as iso8601(3) minus Z; Go parses both" \
  "$KPS" 'timestamp: event\.timestamp\.to_f\.to_s' "$KPS" 'ingested_at: Time\.zone\.now\.iso8601\(3\)\[\.\.\.-1\]' \
  "$REENR" 'timestamp: event\.timestamp\.strftime\("%s\.%3N"\)' \
  "$TIMEGO" 'strconv\.ParseFloat\(timestamp, 64\)' "$TIMEGO" 'time\.Parse\("2006-01-02T15:04:05", s\)'

# ---------------------------------------------------------------- P24/P25 topics and keys
for pair in RAW_EVENTS:"$KPS" RAW_EVENTS:"$RAW_Q" ENRICHED_EVENTS:"$ENR_Q" EVENTS_CHARGED_IN_ADVANCE:"$KARAFKA" EVENTS_DEAD_LETTER:"$DLQ_Q"; do
  t="${pair%%:*}" f="${pair#*:}"
  allhave TOPIC OK FAIL "LAGO_KAFKA_${t}_TOPIC read by Go and by $(basename "$f")" "$MAINP" "\"LAGO_KAFKA_${t}_TOPIC\"" "$f" "LAGO_KAFKA_${t}_TOPIC"
done
if has "$MAINP" 'LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC'; then
  emit CHANGED DRIFT "Go reads LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC again -- re-verify the pinned-SHA drift notes"
elif [ -f "$EXP_Q" ] && has "$EXP_Q" 'LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC'; then
  emit KNOWN DRIFT "Rails CH migration still interpolates LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC ($(where "$EXP_Q" 'LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC')); Go stopped producing it (d9c32b6)"
else emit CHANGED DRIFT "Rails no longer references the expanded topic -- update the pinned-SHA drift notes"; fi
nk="$(grep -cE 'msgKey := fmt\.Sprintf\("%s-%s", event\.OrganizationID, event\.TransactionID\)' "$PRODUCER" || true)"
if [ "$nk" = 2 ]; then emit OK KEYS "Go enriched + in-advance key '<org>-<transaction_id>' (2 sites, $(where "$PRODUCER" 'msgKey := fmt'))"
else emit FAIL KEYS "expected 2 '<org>-<transaction_id>' key sites in $(gl "$PRODUCER"), found $nk"; fi
if awk '/def build_message/,/^    end/' "$KPS" | grep -q 'key:'; then emit CHANGED KEYR "Rails raw producer now sets a Kafka key -- re-verify"
else emit INFO KEYR "Rails raw producer sets no Kafka key ($(where "$KPS" 'def build_message'))"; fi

# ---------------------------------------------------------------- P26-P29, P32/P33 payload schemas and drift
tags() { awk -v s="$2" '$0 ~ "^type "s" struct" {f=1; next} f && /^}/ {f=0} f' "$1" | grep -oE 'json:"[a-z_]+' | sed 's/json:"//' | sort -u; }
cols() { grep -oE 't\.[a-z]+ :[a-z_]+' "$1" | awk '{print $2}' | tr -d ':' | sort -u; }
setdiff() { comm -23 <(echo "$1") <(echo "$2") | tr '\n' ' ' | sed 's/ $//'; }

ENRTAGS="$(tags "$EVENTGO" EnrichedEvent)"; EVTAGS="$(tags "$EVENTGO" Event)"; FTAGS="$(tags "$EVENTGO" FailedEvent)"
miss="$(setdiff "$(cols "$ENR_Q")" "$ENRTAGS")"
if [ -z "$miss" ]; then emit OK SCH1 "every events_enriched_queue column is a Go EnrichedEvent JSON field; Go-only (ignored by CH): $(setdiff "$ENRTAGS" "$(cols "$ENR_Q")")"
else emit FAIL SCH1 "events_enriched_queue columns missing from Go EnrichedEvent JSON: $miss"; fi
miss="$(setdiff "$(cols "$DLQ_Q")" "$FTAGS")"
if [ -z "$miss" ]; then emit OK SCH2 "every events_dead_letter_queue column is a Go FailedEvent JSON field"
else emit FAIL SCH2 "events_dead_letter_queue columns missing from Go FailedEvent JSON: $miss"; fi
mvkeys="$(grep -oE "JSONExtractString\(event, '[a-z_]+'\)" "$DLQ_MV" | sed -E "s/.*'([a-z_]+)'.*/\1/" | sort -u)"
miss="$(setdiff "$mvkeys" "$EVTAGS")"
if [ -z "$miss" ]; then emit OK SCH3 "every event.<key> the DLQ MV extracts ($(basename "$DLQ_MV")) is a Go Event JSON field"
else emit FAIL SCH3 "DLQ MV extracts event keys missing from Go Event JSON: $miss"; fi
railsraw="$(awk '/def build_payload/,/^    end/' "$KPS" | grep -oE '^ {8}[a-z_]+:' | tr -d ' :' | sort -u)"
miss="$(setdiff "$railsraw" "$EVTAGS")"
if [ "$miss" = "external_customer_id" ]; then emit KNOWN SCH4 "raw payload: Go Event drops only external_customer_id (Rails sends it)"
elif [ -z "$miss" ]; then emit CHANGED SCH4 "Go Event now models every Rails raw field -- update payload-schemas.md"
else emit FAIL SCH4 "Rails raw payload keys not modelled by Go Event: $miss"; fi
cfkeys="$( { awk '/when "Hash"/,/when "Event"/' "$CFACT"; awk '/def self.timestamp_from_source/,/^    end/' "$COMMON"; } | grep -oE 'source\["[a-z_]+"\]' | sed -E 's/source\["([a-z_]+)"\]/\1/' | sort -u)"
miss="$(setdiff "$cfkeys" "$ENRTAGS")"
if [ "$miss" = "id timestamp_with_precision" ]; then
  emit OK SCH5 "in-advance: Rails CommonFactory reads only Go EnrichedEvent fields, plus id/timestamp_with_precision which Go omits by design (id nil = Kafka origin; float timestamp fallback)"
else emit FAIL SCH5 "Rails CommonFactory hash keys vs Go EnrichedEvent: unexpected missing set '$miss' (expected 'id timestamp_with_precision')"; fi
if has "$EVENTGO" 'json:"reprocess"'; then emit CHANGED REPR "Go SourceMetadata models reprocess again -- update drift notes"
elif has "$REENR" 'reprocess:$'; then emit KNOWN REPR "Rails re-enrichment still sends source_metadata.reprocess ($(where "$REENR" 'reprocess:$')); Go ignores it since d9c32b6"
else emit CHANGED REPR "Rails re-enrichment no longer sends reprocess -- update drift notes"; fi
nonehave HIST OK CHANGED "Go no longer builds Rails charge-usage cache keys (removed 2fd8e8b)" "$(G processors/events_processor/processor.go)" 'charge-usage|ChargeCache'
allhave DLY INFO CHANGED "Rails delays in-advance processing by CLICKHOUSE_MERGE_DELAY = 15.seconds" "$CHSTORE" 'CLICKHOUSE_MERGE_DELAY = 15\.seconds'
allhave CHTS OK FAIL "CH enriched MV parses the Go float timestamp with toDateTime64(timestamp, 3) and properties as Map(String, String)" \
  "$ENR_MV" 'toDateTime64\(timestamp, 3\) AS timestamp' "$ENR_MV" "JSONExtract\(properties, 'Map\(String, String\)'\) AS properties"

echo "summary: OK=$nOK KNOWN=$nKNOWN INFO=$nINFO FAIL=$nFAIL CHANGED=$nCHANGED"
if [ "$nFAIL" -gt 0 ]; then exit 1; fi
if [ "$nCHANGED" -gt 0 ]; then exit 3; fi
exit 0
