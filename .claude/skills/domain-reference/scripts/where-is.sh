#!/usr/bin/env bash
# where-is.sh — find where a billing-domain term lives in code, in BOTH implementations:
# the Go events-processor (this repo) and lago-api at the pinned gitlink SHA ($API).
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/domain-reference/scripts/where-is.sh [options] <term>
#   .claude/skills/domain-reference/scripts/where-is.sh --list
#
#   <term>     a glossary term ("pay_in_advance", "subscription refresh", "ALL_FILTER_VALUES") or any
#              literal string. Known terms (see --list) expand to curated regexes. Any other snake_case
#              term also matches its CamelCase form (precise_total_amount_cents -> PreciseTotalAmountCents).
#   -E         treat <term> as an extended regex, used verbatim on both sides (no expansion)
#   -C N       lines of context (default 0)
#   -m N       max matching lines printed per side (default 40; 0 = unlimited)
#   --ep       events-processor only          --api   lago-api only
#   --tests    include Go *_test.go files and lago-api spec/ (excluded by default)
#   --wide     lago-api: also search lib/ and config/ (default: app/ db/ clock.rb karafka.rb)
#   --list     print the curated term -> regex table and exit
#
# Output: one block per side; every hit is printed citation-ready:
#   events-processor/<path>:<line>:<text>      and      $API/<path>:<line>:<text>
# $API is obtained with research-methodology's pinned-checkout.sh (first run clones lago-api at the
# pinned SHA into ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}; needs network once).
# Read-only: uses `git grep` on the working tree of each checkout; writes nothing to the repo
# (one temp file for git grep's stderr, removed on exit).
#
# Exit codes: 0 = at least one hit; 1 = no hit on any searched side; 2 = usage error, an invalid
#             regex (git grep error), or a checkout could not be obtained.
set -euo pipefail

usage() { awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; }

# Curated terms: <key>|<ERE alternation>. The key is the term lowercased with spaces/dashes as "_".
# The whole alternation is searched on BOTH sides (a Rails-only token never matches Go and vice
# versa), so one row serves both repos. Keep rows free of \b (not portable across grep engines).
read -r -d '' TERMS <<'EOF' || true
organization|OrganizationID|organization_id|current_organization
customer|class Customer |has_many :customers|belongs_to :customer|external_customer_id
user|class User |has_secure_password|has_many :users|has_many :memberships
external_customer_id|external_customer_id|ExternalCustomerID
subscription|type Subscription struct|FetchSubscription|SearchSubscriptions|class Subscription |STATUSES = 
external_subscription_id|ExternalSubscriptionID|external_subscription_id
plan|PlanID|class Plan |INTERVALS = 
billable_metric|type BillableMetric struct|FetchBillableMetric|GetBillableMetric|class BillableMetric |AGGREGATION_TYPES = 
aggregation_type|AggregationType|AGGREGATION_TYPES|aggregation_type|AggregationFactory
field_name|FieldName|field_name
expression|bm\.Expression|expression\.Evaluate|CalculateExpressionService|Lago::Event|ExpressionParser
recurring|Recurring|recurring
billable_metric_filter|BillableMetricFilter|billable_metric_filter
charge|type Charge struct|HasPayInAdvanceCharge|class Charge |CHARGE_MODELS
charge_model|charge_model|CHARGE_MODELS|ChargeModels::Factory
pay_in_advance|PayInAdvance|pay_in_advance
invoiceable|invoiceable
prorated|[Pp]rorated|ProratedAggregations
charge_filter|ChargeFilter|charge_filter|EventMatchingService|MatchingAndIgnoredService
all_filter_values|ALL_FILTER_VALUES
event|type Event struct|ToEnrichedEvent|class Event < |Events::CreateService|class KafkaProducerService
transaction_id|TransactionID|transaction_id|DEDUP_KEY_COLUMNS|already_processed
timestamp|ToTime\(|ToFloat64Timestamp|def parse_timestamp|timestamp\.to_f|strftime\("%s
ingested_at|IngestedAt|ingested_at|CustomTime
precise_total_amount_cents|PreciseTotalAmountCents|precise_total_amount_cents
source|HTTP_RUBY|http_ruby|NotAPIPostProcessed|EVENT_SOURCE|api_post_processed
api_post_processed|ApiPostProcess|NotAPIPostProcessed|api_post_processed
enriched_event|EnrichedEvent|EnrichService|events_enriched
events_enriched|events_enriched|EnrichedEventsTopic|EventsEnriched
events_raw|RawEventsTopic|events_raw|EventsRaw|RAW_EVENTS_TOPIC
dead_letter|DeadLetter|dead_letter|FailedEvent|EventsDeadLetter
pre_aggregation|events_enriched_expanded|events_aggregated|AggregatingMergeTree|pre_filter_events
events_store|api_post_processed|clickhouse_events_store|postgres_events_store|StoreFactory|supports_clickhouse
wallet|ongoing_balance|awaiting_wallet_refresh|flag_wallets_for_refresh|target_wallet_code|RefreshWalletJob
alert|UsageMonitoring::Alert|STI_MAPPING|TrackSubscriptionActivityService|SubscriptionActivity
usage_threshold|usage_threshold|UsageThreshold|progressive_billing
subscription_refresh|subscription_refreshed|FlagSubscriptionRefresh|SUBSCRIPTION_BUCKET_DURATION|FlagRefreshed
invoice|INVOICE_TYPES|Invoices::SubscriptionService|CalculateFeesService|BillSubscriptionJob|SubscriptionsBillerJob
fee|class Fee |FEE_TYPES|Fees::ChargeService|init_metered_items_fees
billing_period|charges_from_datetime|charges_to_datetime|DatesService|BillingPeriodBoundaries
in_advance|ChargedInAdvance|charged_in_advance|PayInAdvanceJob|CLICKHOUSE_MERGE_DELAY
memory_cache|LAGO_USE_MEMORY_CACHE|memCache|NewCache
value|enrichedEvent\.Value|decimal_value|toDecimal128OrZero|arel_table\[:value\]
EOF

ep_only=0 api_only=0 tests=0 wide=0 regex=0 ctx=0 max=40 term=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list) printf '%-26s %s\n' "TERM" "ERE searched in events-processor AND \$API"
            printf '%s\n' "$TERMS" | while IFS= read -r row; do
              [ -n "$row" ] || continue
              printf '%-26s %s\n' "${row%%|*}" "${row#*|}"; done
            exit 0 ;;
    --ep) ep_only=1 ;;
    --api) api_only=1 ;;
    --tests) tests=1 ;;
    --wide) wide=1 ;;
    -E) regex=1 ;;
    -C) shift; ctx="${1:?-C needs a number}" ;;
    -m) shift; max="${1:?-m needs a number}" ;;
    --) shift; term="${1:-}"; break ;;
    -*) echo "where-is: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) term="$1" ;;
  esac
  shift
done
[ -n "$term" ] || { usage >&2; exit 2; }
case "$ctx$max" in *[!0-9]*) echo "where-is: -C and -m take integers" >&2; exit 2 ;; esac

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "where-is: run inside the lago repo" >&2; exit 2; }
[ -d "$repo/events-processor" ] || { echo "where-is: $repo has no events-processor/ (wrong repo?)" >&2; exit 2; }

# Escape a literal for ERE.
ere_escape() { printf '%s' "$1" | sed -e 's/[][\.^$*+?(){}|/]/\\&/g'; }
camel() { printf '%s' "$1" | awk -F_ '{for(i=1;i<=NF;i++){printf "%s", toupper(substr($i,1,1)) substr($i,2)}}'; }

key="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]' | tr ' -' '__')"
ep_re="" api_re=""
if [ "$regex" -eq 1 ]; then
  ep_re="$term"; api_re="$term"
else
  line="$(awk -F'|' -v k="$key" '$1==k {print; exit}' <<< "$TERMS")"
  if [ -n "$line" ]; then
    ep_re="${line#*|}"; api_re="$ep_re"
  else
    lit="$(ere_escape "$term")"
    ep_re="$lit"; api_re="$lit"
    case "$term" in
      *_*) c="$(camel "$term")"; ep_re="$lit|$c"; api_re="$lit|$c" ;;
    esac
  fi
fi

hits=0
errf="$(mktemp "${TMPDIR:-/tmp}/where-is.XXXXXX")"
trap 'rm -f "$errf"' EXIT
print_block() { # label, dir, prefix, regex, pathspecs...
  local label="$1" dir="$2" prefix="$3" re="$4"; shift 4
  local out n rc=0
  echo "== $label"
  out="$(git -C "$dir" grep -n -I -E -C "$ctx" -e "$re" -- "$@" 2>"$errf")" || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "   (no match for /$re/)"
    return 0
  elif [ "$rc" -ne 0 ]; then
    echo "where-is: git grep failed in $dir (invalid regex?): $(head -n1 "$errf")" >&2
    exit 2
  fi
  # Here-strings, not pipes: with pipefail an early-exiting reader would SIGPIPE the writer
  # (exit 141, truncated output) on terms with many hits.
  n="$(grep -cE '^[^:]+:[0-9]+:' <<< "$out" || true)"
  hits=$((hits + n))
  if [ "$max" -gt 0 ]; then
    awk -v p="$prefix" -v m="$max" '
      /^[^:]+:[0-9]+:/ {c++} c>m {stop=1} c==m && /^--$/ {stop=1} !stop {print p $0}' <<< "$out"
    [ "$n" -le "$max" ] || echo "   ... $((n - max)) more matching lines (use -m 0 or narrow the term)"
  else
    sed "s|^|$prefix|" <<< "$out"
  fi
  echo "   [$n matching lines]"
}

if [ "$api_only" -eq 0 ]; then
  ep_specs=(events-processor ':(exclude)events-processor/go.sum')
  [ "$tests" -eq 1 ] || ep_specs+=(':(exclude)*_test.go' ':(exclude)events-processor/tests')
  # Label = last commit that touched events-processor/ (HEAD may carry skills-only commits on top);
  # "+dirty" when the searched working tree differs from it.
  ep_ver="$(git -C "$repo" log -1 --format=%h -- events-processor)"
  [ -z "$(git --no-optional-locks -C "$repo" status --porcelain -- events-processor 2>/dev/null)" ] || ep_ver="$ep_ver+dirty"
  print_block "events-processor @ $ep_ver" "$repo" "" "$ep_re" "${ep_specs[@]}"
fi

if [ "$ep_only" -eq 0 ]; then
  API="$("$repo/.claude/skills/research-methodology/scripts/pinned-checkout.sh" api)" || {
    echo "where-is: could not obtain the pinned lago-api checkout (see research-methodology)" >&2; exit 2; }
  api_specs=(app db clock.rb karafka.rb ':(exclude)db/structure.sql' ':(exclude)db/schema.rb')
  [ "$wide" -eq 1 ] && api_specs+=(lib config)
  [ "$tests" -eq 1 ] && api_specs+=(spec)
  print_block "lago-api @ $(git -C "$API" rev-parse --short HEAD) (\$API)" "$API" '$API/' "$api_re" "${api_specs[@]}"
fi

[ "$hits" -gt 0 ] || exit 1
exit 0
