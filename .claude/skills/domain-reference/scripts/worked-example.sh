#!/usr/bin/env bash
# worked-example.sh — push real-shaped raw events through the REAL events-processor code path
# (EventProcessor.ProcessEvents, the function the Kafka consumer calls) and then through the
# ClickHouse expressions of the events_enriched queue/MV/table, and check the outcome.
# It is the executable form of SKILL.md "Worked example".
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/domain-reference/scripts/worked-example.sh            # Go + ClickHouse stages
#   .claude/skills/domain-reference/scripts/worked-example.sh --no-ch    # Go stage only
#   .claude/skills/domain-reference/scripts/worked-example.sh --ch-bin /path/to/clickhouse
#   .claude/skills/domain-reference/scripts/worked-example.sh --raw      # do not mask volatile fields
#
# Go stage: a test file is mapped into processors/events_processor with `go test -overlay`
#   (nothing is written into the repo). Lookups use the in-memory cache (badger) seeded with one
#   sum BM "storage" (field_name gb), one count BM "api_calls", one BM with an expression, one
#   subscription and one pay_in_advance charge, for a CH-store org and a PG-store org (the dev seed
#   org ids). Producers are captured in memory; the Redis refresh flag uses the REAL FlagStore on
#   miniredis. Needs CGO: sources build-and-env's ep-env.sh (builds libexpression_go once).
# ClickHouse stage: feeds the captured events_enriched messages to `clickhouse local` with the
#   events_enriched_queue structure and the MV/table expressions (toDateTime64, JSONExtract Map,
#   toDecimal128OrZero(value, 26)). Binary: --ch-bin, $CH_BIN, the first
#   ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/clickhouse-*/clickhouse or .../clickhouse/*/clickhouse,
#   or `clickhouse` on PATH. None found -> the stage prints SKIP (it never downloads; to fetch one,
#   see the diagnostics-and-tooling skill, ClickHouse local).
#
# Exit codes: 0 every CHECK matched; 1 at least one CHECK MISMATCH (domain behaviour changed:
#             re-verify the skill); 2 usage error, CGO env failure or the overlay test failed to build/run.
set -euo pipefail

usage() { awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; }
no_ch=0 raw=0 ch_bin="${CH_BIN:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-ch) no_ch=1 ;;
    --raw) raw=1 ;;
    --ch-bin) shift; ch_bin="${1:?--ch-bin needs a path}" ;;
    *) echo "worked-example: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "worked-example: run inside the lago repo" >&2; exit 2; }
command -v go >/dev/null 2>&1 || { echo "worked-example: go not found (see build-and-env)" >&2; exit 2; }
# shellcheck disable=SC1091
source "$repo/.claude/skills/build-and-env/scripts/ep-env.sh" >/dev/null || {
  echo "worked-example: ep-env.sh failed (see build-and-env)" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/domainref-worked.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
target="$repo/events-processor/processors/events_processor/zz_domainref_worked_example_test.go"
[ ! -e "$target" ] || { echo "worked-example: $target exists in the repo; refusing to shadow it" >&2; exit 2; }

cat > "$tmp/worked_test.go" <<'GO'
package events_processor

// Overlay-only test for .claude/skills/domain-reference/scripts/worked-example.sh. Never committed.

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	goredis "github.com/redis/go-redis/v9"
	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/config/kafka"
	"github.com/getlago/lago/events-processor/config/redis"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

type domainRefMsg struct{ topic, key, value string }

type domainRefProducer struct {
	topic string
	mu    *sync.Mutex
	out   *[]domainRefMsg
}

func (p domainRefProducer) Produce(_ context.Context, m *kafka.ProducerMessage) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	*p.out = append(*p.out, domainRefMsg{p.topic, string(m.Key), string(m.Value)})
	return true
}

func (p domainRefProducer) GetTopic() string { return p.topic }

func TestDomainRefWorkedExample(t *testing.T) {
	const orgCH = "22222222-3333-4444-5555-666666666666" // dev seed "Hooli Clickhouse" (CH-store org)
	const orgPG = "11111111-2222-3333-4444-555555555555" // dev seed "Hooli" (PG-store org)

	memCache, err := cache.NewCache(cache.CacheConfig{Context: context.Background()})
	if err != nil {
		t.Fatal(err)
	}
	defer memCache.Close()

	must := func(r utils.Result[bool]) {
		if r.Failure() {
			t.Fatal(r.ErrorMsg())
		}
	}
	for _, org := range []string{orgCH, orgPG} {
		o := org
		p := o[:4]
		must(memCache.SetBillableMetric(&models.BillableMetric{ID: "bm-storage-" + p, OrganizationID: o, Code: "storage",
			AggregationType: models.AggregationTypeSum, FieldName: "gb", UpdatedAt: utils.NowNullTime()}))
		must(memCache.SetBillableMetric(&models.BillableMetric{ID: "bm-calls-" + p, OrganizationID: o, Code: "api_calls",
			AggregationType: models.AggregationTypeCount, FieldName: "ignored_for_count", UpdatedAt: utils.NowNullTime()}))
		must(memCache.SetBillableMetric(&models.BillableMetric{ID: "bm-expr-" + p, OrganizationID: o, Code: "storage_expr",
			AggregationType: models.AggregationTypeSum, FieldName: "gb", Expression: "event.properties.mb / 1024", UpdatedAt: utils.NowNullTime()}))
		must(memCache.SetSubscription(&models.Subscription{ID: "sub-" + p, OrganizationID: &o, ExternalID: "sub_ext_42",
			PlanID: "plan-" + p, StartedAt: utils.NewNullTime(time.Date(2024, 9, 1, 0, 0, 0, 0, time.UTC)), UpdatedAt: utils.NowNullTime()}))
		must(memCache.SetCharge(&models.Charge{ID: "charge-" + p, OrganizationID: o, PlanID: "plan-" + p,
			BillableMetricID: "bm-storage-" + p, PayInAdvance: true, UpdatedAt: utils.NowNullTime()}))
	}

	mr := miniredis.RunT(t)
	flagStore := models.NewFlagStore(&redis.RedisDB{Client: goredis.NewClient(&goredis.Options{Addr: mr.Addr()})}, "subscription_refreshed_v2")

	var mu sync.Mutex
	var out []domainRefMsg
	proc := NewEventProcessor(
		NewEventEnrichmentService(nil, memCache),
		NewEventProducerService(
			domainRefProducer{"events_enriched", &mu, &out},
			domainRefProducer{"events_charged_in_advance", &mu, &out},
			domainRefProducer{"events_dead_letter", &mu, &out},
		),
		NewSubscriptionRefreshService(flagStore),
	)

	// Same shape and field order as Rails Events::KafkaProducerService#build_payload.
	ingested := time.Now().UTC().Format("2006-01-02T15:04:05.000")
	raw := func(org, tx, code, props, source string, apiPostProcessed bool) string {
		src := ""
		if source != "" {
			src = fmt.Sprintf(`,"source":%q,"source_metadata":{"api_post_processed":%t}`, source, apiPostProcessed)
		}
		return fmt.Sprintf(`{"organization_id":%q,"external_customer_id":null,"external_subscription_id":"sub_ext_42",`+
			`"transaction_id":%q,"timestamp":"1727787600.123","code":%q,"precise_total_amount_cents":"0.0",`+
			`"properties":%s,"ingested_at":%q%s}`, org, tx, code, props, ingested, src)
	}

	cases := []struct{ label, value string }{
		{"E1 CH-store org, Rails payload, sum BM storage, gb=12.5 (THE worked example)", raw(orgCH, "tx-e1", "storage", `{"gb":12.5,"region":"eu"}`, "http_ruby", false)},
		{"E2 same event from a PG-store org (api_post_processed=true)", raw(orgPG, "tx-e2", "storage", `{"gb":12.5,"region":"eu"}`, "http_ruby", true)},
		{"E3 CH-store org, gb=2000000 (JSON number >= 1e6)", raw(orgCH, "tx-e3", "storage", `{"gb":2000000}`, "http_ruby", false)},
		{"E4 CH-store org, property gb missing", raw(orgCH, "tx-e4", "storage", `{"region":"eu"}`, "http_ruby", false)},
		{"E5 CH-store org, count BM (its field_name is ignored)", raw(orgCH, "tx-e5", "api_calls", `{"ignored_for_count":7}`, "http_ruby", false)},
		{"E6 connector-shaped event (no source), BM expression event.properties.mb / 1024", raw(orgCH, "tx-e6", "storage_expr", `{"mb":"3072"}`, "", false)},
		{"E7 CH-store org, unknown BM code", raw(orgCH, "tx-e7", "no_such_metric", `{}`, "http_ruby", false)},
	}

	var report strings.Builder
	for _, c := range cases {
		mu.Lock()
		out = nil
		mu.Unlock()
		mr.FlushAll()
		processed := proc.ProcessEvents(context.Background(), []*kgo.Record{{Topic: "events-raw", Value: []byte(c.value)}})
		fmt.Fprintf(&report, "== %s\nRAW    %s\n", c.label, c.value)
		mu.Lock()
		sort.SliceStable(out, func(i, j int) bool { return out[i].topic < out[j].topic })
		for _, m := range out {
			fmt.Fprintf(&report, "OUT    topic=%s key=%q\n       %s\n", m.topic, m.key, m.value)
		}
		mu.Unlock()
		members, _ := mr.ZMembers("subscription_refreshed_v2")
		fmt.Fprintf(&report, "REDIS  subscription_refreshed_v2 members=%v\n", members)
		fmt.Fprintf(&report, "COMMIT marked_processed=%t\n", len(processed) == 1)
	}
	if err := os.WriteFile(os.Getenv("DOMAINREF_OUT"), []byte(report.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}
GO

printf '{"Replace":{"%s":"%s"}}\n' "$target" "$tmp/worked_test.go" > "$tmp/overlay.json"
echo "## Go stage: go test -overlay ... -run TestDomainRefWorkedExample ./processors/events_processor/"
if ! (cd "$repo/events-processor" && DOMAINREF_OUT="$tmp/report.txt" \
      go test -count=1 -overlay "$tmp/overlay.json" -run '^TestDomainRefWorkedExample$' ./processors/events_processor/ \
      > "$tmp/gotest.log" 2>&1); then
  cat "$tmp/gotest.log" >&2
  echo "worked-example: overlay test failed to build or run (events-processor changed? see above)" >&2
  exit 2
fi

mask() {
  if [ "$raw" -eq 1 ]; then cat; return; fi
  sed -E -e 's/"ingested_at":"[0-9T:.-]+"/"ingested_at":"<now>"/g' \
         -e 's/"failed_at":"[^"]+"/"failed_at":"<now>"/g' \
         -e 's/\|[0-9]{10}\]/|<bucket>]/g'
}
mask < "$tmp/report.txt"

fails=0
check() { # label, fixed string expected in the section of case $2
  local label="$1" case_id="$2" want="$3" section
  section="$(awk -v c="== $case_id " 'index($0,c)==1{on=1;print;next} /^== /{on=0} on' "$tmp/report.txt")"
  if grep -qF -- "$want" <<< "$section"; then
    echo "CHECK ok        $case_id $label"
  else
    echo "CHECK MISMATCH  $case_id $label (expected to find: $want)"; fails=$((fails + 1))
  fi
}
check_absent() {
  local label="$1" case_id="$2" bad="$3" section
  section="$(awk -v c="== $case_id " 'index($0,c)==1{on=1;print;next} /^== /{on=0} on' "$tmp/report.txt")"
  if grep -qF -- "$bad" <<< "$section"; then
    echo "CHECK MISMATCH  $case_id $label (unexpected: $bad)"; fails=$((fails + 1))
  else
    echo "CHECK ok        $case_id $label"
  fi
}
echo
echo "## Checks (Go stage)"
check "value is the property rendered with %v" E1 '"value":"12.5"'
check "timestamp is float seconds, ms kept" E1 '"timestamp":1727787600.123'
check "enriched key is <org>-<transaction_id>" E1 'topic=events_enriched key="22222222-3333-4444-5555-666666666666-tx-e1"'
check "CH-store org: in-advance message produced (pay_in_advance charge)" E1 'topic=events_charged_in_advance'
check "CH-store org: refresh member <org>:<sub>|<bucket>" E1 'members=[22222222-3333-4444-5555-666666666666:sub-2222|'
check "PG-store org: still enriched" E2 'topic=events_enriched'
check_absent "PG-store org: no in-advance message" E2 'topic=events_charged_in_advance'
check "PG-store org: no refresh flag" E2 'members=[]'
check "JSON number 2000000 becomes \"2e+06\"" E3 '"value":"2e+06"'
# json.Marshal escapes < and > ; build the literal \u003c sequence with printf so no tool unescapes it
nil_on_wire="$(printf '"value":"%su003cnil%su003e"' "\\" "\\")"
check "missing property becomes \"<nil>\" (JSON-escaped on the wire)" E4 "$nil_on_wire"
check "Go still emits in-advance when the property is missing (Rails decides later)" E4 'topic=events_charged_in_advance'
check "count BM value is \"1\"" E5 '"value":"1"'
check "Go evaluated the expression (no source) and wrote properties[field_name] as a string" E6 '"properties":{"gb":"3","mb":"3072"}'
check "unknown BM code goes to the DLQ" E7 '"error_code":"fetch_billable_metric"'
check "the DLQ'd record is still committed" E7 'COMMIT marked_processed=true'

# ---------------------------------------------------------------- ClickHouse stage
echo
if [ "$no_ch" -eq 1 ]; then
  echo "## ClickHouse stage: SKIP (--no-ch)"
else
  if [ -z "$ch_bin" ]; then
    cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
    for c in "$cache"/clickhouse-*/clickhouse "$cache"/clickhouse/*/clickhouse; do
      [ -x "$c" ] && { ch_bin="$c"; break; }
    done
    [ -n "$ch_bin" ] || ch_bin="$(command -v clickhouse 2>/dev/null || true)"
  fi
  if [ -z "$ch_bin" ] || [ ! -x "$ch_bin" ]; then
    echo "## ClickHouse stage: SKIP (no clickhouse binary; pass --ch-bin, or fetch one via the diagnostics-and-tooling skill)"
  else
    echo "## ClickHouse stage: $("$ch_bin" local --version 2>/dev/null | head -n1)"
    awk '/^OUT    topic=events_enriched /{getline; sub(/^ +/, ""); print}' "$tmp/report.txt" > "$tmp/enriched.jsonl"
    structure="organization_id String, external_subscription_id String, code String, timestamp String, transaction_id String, properties String, value Nullable(String), precise_total_amount_cents Nullable(Decimal(40, 15))"
    echo "-- events_enriched_queue -> events_enriched_mv -> events_enriched column defaults"
    "$ch_bin" local --session_timezone=UTC --input-format JSONEachRow --structure "$structure" --query "
      SELECT transaction_id, code, toDateTime64(timestamp, 3) AS timestamp,
             JSONExtract(properties, 'Map(String, String)') AS properties, value,
             toDecimal128OrZero(value, 26) AS decimal_value
      FROM table ORDER BY transaction_id FORMAT TSVWithNames" < "$tmp/enriched.jsonl" | tee "$tmp/ch1.tsv"
    echo "-- what a sum / unique_count over code=storage of the CH-store org would see (E1+E3+E4)"
    "$ch_bin" local --session_timezone=UTC --input-format JSONEachRow --structure "$structure" --query "
      SELECT count() AS events, sum(toDecimal128OrZero(value, 26)) AS sum_decimal_value,
             uniqExact(value) AS distinct_value_strings
      FROM table WHERE organization_id = '22222222-3333-4444-5555-666666666666' AND code = 'storage'
      FORMAT TSVWithNames" < "$tmp/enriched.jsonl" | tee "$tmp/ch2.tsv"
    echo
    echo "## Checks (ClickHouse stage)"
    chk() { if grep -qP -- "$2" "$3"; then echo "CHECK ok        CH $1"; else echo "CHECK MISMATCH  CH $1 (pattern: $2)"; fails=$((fails + 1)); fi; }
    chk "E1 timestamp lands as DateTime64(3) 2024-10-01 13:00:00.123" '^tx-e1\tstorage\t2024-10-01 13:00:00\.123\t' "$tmp/ch1.tsv"
    chk "E1 decimal_value 12.5" '^tx-e1\t.*\t12\.5\t12\.5$' "$tmp/ch1.tsv"
    chk "E3 \"2e+06\" parses to 2000000 while properties keep '2000000'" "^tx-e3\t.*'gb':'2000000'.*\t2e\+06\t2000000$" "$tmp/ch1.tsv"
    chk "E4 \"<nil>\" becomes decimal_value 0" '^tx-e4\t.*\t<nil>\t0$' "$tmp/ch1.tsv"
    chk "sum over E1+E3+E4 = 2000012.5, 3 distinct value strings (\"<nil>\" counts)" '^3\t2000012\.5\t3$' "$tmp/ch2.tsv"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all checks matched"; exit 0; fi
echo "RESULT: $fails check(s) MISMATCH - domain behaviour changed; re-verify domain-reference (and rails-go-parity)"
exit 1
