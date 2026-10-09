# Worked examples: hunch -> card -> probe -> verdict -> record

Read this when you are about to run your first probe here, or when you need a model of a complete
hypothesis card. Every command below was run on 2026-10-01. Code facts as of `5308258`
(events-processor tree `83e012866f29`); the working branch may carry skills-only commits on top.
History clone `H` (776 commits); pinned lago-api `591ae90` (2026-09-08).

Conventions: run from the repo root; `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`;
`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`. Scratch work goes in
`$TMPDIR` (change-control N10). Nothing here writes into the repo.

---

## Example A: "retryable failures are redelivered" -> REFUTED, then REFINED and ACCEPTED

### Card

<!-- evidence-check: off (card fields; the evidence is the probe and output below) -->
| Field | Value |
|---|---|
| ID / date | RM-A, 2026-10-01 |
| Hunch and its source | Two code comments say so: `events-processor/processors/events_processor/processor.go:75-76` ("It will be consumed again and reprocessed") and `events-processor/config/kafka/consumer.go:97` ("records will be re-polled after the next rebalance"). Comments are a hunch source, not evidence. |
| Hypothesis | A record whose processing fails retryably is delivered to the consumer group again after a consumer restart. |
| Prediction (written BEFORE running) | Single partition. After one restart in the same group, the failing record's delivery count = **2** (1 redelivery), whether or not later records arrive. |
| Why this probe discriminates | It drives the REAL `kafka.NewConsumerGroup` (`events-processor/config/kafka/consumer.go:227`) and its commit rule, with only the per-record processing stubbed. A unit test of `findMaxCommitableRecord` alone cannot show what the committed offset does across polls. |
| Control | Identical run without the later records. If the control does not redeliver either, the probe itself is broken. |
| Cost | About 10 s per run, no Docker, no Postgres. |

<!-- evidence-check: on -->

### Mechanism you can read before running (code read, VERIFIED)

- `processRecordsAndCommit` commits the longest processed prefix (`events-processor/config/kafka/consumer.go:82-109`).
- If no record of the batch is commitable it skips the commit (`events-processor/config/kafka/consumer.go:94-100`).
- The retry branch returns without marking the record processed (`events-processor/processors/events_processor/processor.go:74-79`).
- Nothing remembers the hole. A later batch on the same partition whose records all succeed commits its last record (`CommitRecords`, `events-processor/config/kafka/consumer.go:104`), which moves the committed offset past the failed one.

The code read predicts the refutation, but only the run proves the committed offset really moves.

### Probe (published exactly as run)

Build it in scratch, never in the repo:

```bash
REPO=$(git rev-parse --show-toplevel)          # run this line inside the repo
W=$(mktemp -d) && cd "$W"
# save the listing below as main.go, then:
go mod init probe-rm-a
go mod edit -replace "github.com/getlago/lago/events-processor=$REPO/events-processor" \
            -require github.com/getlago/lago/events-processor@v0.0.0
go get github.com/twmb/franz-go@v1.20.5 github.com/twmb/franz-go/pkg/kfake@2b5c574e9ddd
go mod tidy && go run . && go run . -control
```

The module needs Go >= 1.25 (the `events-processor/go.mod` `go` line); with an older local Go,
the default `GOTOOLCHAIN=auto` downloads a newer toolchain on the first `go get` (see `build-and-env`).
The kfake pseudo-version `2b5c574e9ddd` is the one that works with the
pinned franz-go v1.20.5. On 2026-10-01 `go get github.com/twmb/franz-go/pkg/kfake@latest` resolved to
`v0.0.0-20260927204940-b5a45ccfdf7e`, which requires franz-go v1.21.7 and go >= 1.26.0. Requested
together with `franz-go@v1.20.5` (as above), `go get` refuses it ("requires github.com/twmb/franz-go@v1.21.7,
not … v1.20.5"). Requested alone, it silently upgrades franz-go (v1.21.7), kmsg (v1.14.0) and the
module's `go` line (1.26.0). The reusable kfake harness lives in the
`diagnostics-and-tooling` skill; this listing only shows how a treatment/control pair is built.

```go
// Probe for hypothesis RM-A: "a retryably failed record is redelivered after a restart".
// Treatment: a later poll on the same partition commits. Control (-control): no later poll.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/getlago/lago/events-processor/config/kafka"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
)

func main() {
	control := flag.Bool("control", false, "do not produce the later records")
	flag.Parse()
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(1, "raw"))
	if err != nil {
		panic(err)
	}
	defer c.Close()
	prod, _ := kgo.NewClient(kgo.SeedBrokers(c.ListenAddrs()...), kgo.DefaultProduceTopic("raw"))
	defer prod.Close()

	var mu sync.Mutex
	seen := map[string]int{}
	// Same contract as processor.go:74-79: a retryable failure is simply NOT returned.
	process := func(_ context.Context, recs []*kgo.Record) []*kgo.Record {
		mu.Lock()
		defer mu.Unlock()
		out := []*kgo.Record{}
		for _, r := range recs {
			seen[string(r.Value)]++
			if string(r.Value) != "retryable-fail" {
				out = append(out, r)
			}
		}
		return out
	}
	run := func(label string, produce func()) {
		ctx, cancel := context.WithCancel(context.Background())
		cg, err := kafka.NewConsumerGroup(kafka.ServerConfig{Servers: c.ListenAddrs()},
			&kafka.ConsumerGroupConfig{Topic: "raw", ConsumerGroup: "probe", ProcessRecords: process})
		if err != nil {
			panic(err)
		}
		done := make(chan struct{})
		go func() { cg.Start(ctx); close(done) }()
		if produce != nil {
			produce()
		}
		time.Sleep(3 * time.Second)
		cancel()
		<-done
		mu.Lock()
		fmt.Printf("%s: deliveries %v\n", label, seen)
		mu.Unlock()
	}
	run("consumer #1", func() {
		time.Sleep(1500 * time.Millisecond)
		prod.ProduceSync(context.Background(), &kgo.Record{Value: []byte("retryable-fail")})
		if !*control { // a LATER poll on the same partition
			time.Sleep(700 * time.Millisecond)
			prod.ProduceSync(context.Background(), &kgo.Record{Value: []byte("ok-1")}, &kgo.Record{Value: []byte("ok-2")})
		}
	})
	run("consumer #2 (restart, same group)", nil) // resumes from the committed offset
}
```

### Observed (2026-10-01, 4 of 4 runs identical; an independent re-run gave 4 of 4 again)

```
treatment  consumer #2 (restart, same group): deliveries map[ok-1:1 ok-2:1 retryable-fail:1]
control    consumer #2 (restart, same group): deliveries map[retryable-fail:2]
```

### Verdict and record

<!-- evidence-check: off (verdict over the observed output above) -->
- Prediction "2 deliveries" vs treatment 1 delivery (0 redeliveries): **REFUTED** as stated.
- Control gave 2 deliveries, so the probe can see a redelivery. The refutation is real, not a probe defect.
- **Refined claim (ACCEPTED):** a retryable failure is redelivered only if no later batch on the same partition commits first. Otherwise its offset is committed past, and it never reaches the DLQ.
- The ingredients that matter are a separate later poll and a successful commit. Inside a single batch `[fail, ok, ok]` the processed prefix is empty, so nothing is committed.
- **Where it was recorded:**
  - as-is behaviour: the `architecture-contract` skill;
  - remediation: the `event-accounting-campaign` skill, workstream W1;
  - the rule that forbids changing commit semantics without a kfake test, ADR-001 conformance and owner sign-off: change-control N7; the delivery contract itself is ADR-001 (DECIDED OD-2 (owner, 2026-10-02), delegated).
<!-- evidence-check: on -->

---

## Example B: "ClickHouse cannot parse `1e+06`" -> REFUTED; the real loss is >= 1e12

### Card

<!-- evidence-check: off (card fields; the evidence is the commands and outputs below) -->
| Field | Value |
|---|---|
| ID / date | RM-B, 2026-10-01 |
| Hunch and its source | Go builds `value` with `fmt.Sprintf("%v", ...)` on a float64 (`events-processor/processors/events_processor/enrichment_service.go:114`). That prints `1e+06` for one million. ClickHouse fills `decimal_value` with `toDecimal128OrZero(value, 26)` (`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`). Suspicion: exponent strings do not parse, so sums become 0. |
| Hypothesis | `toDecimal128OrZero('1e+06', 26)` returns 0. |
| Prediction | `'1e+06'` -> **0**, `'1.2345678e+07'` -> **0**. Controls: `'1000000'` -> 1000000. |
| Discriminating probe | Run the real ClickHouse function on a corpus that includes the suspect strings and boundary controls (12 integer digits is the limit of `Decimal(38,26)`). |
| Cost | Seconds once a `clickhouse local` binary exists. Fetching it is tooling: `.claude/skills/diagnostics-and-tooling/scripts/ch-local.sh --path` downloads it once into the shared cache and prints its path. Record the version you ran. |

<!-- evidence-check: on -->

### Step 1: the cheap part, the Go strings (VERIFIED)

```bash
W=$(mktemp -d) && cat > "$W/main.go" <<'EOF'
package main

import (
	"encoding/json"
	"fmt"
)

func main() {
	var m map[string]any
	_ = json.Unmarshal([]byte(`{"a":999999,"b":1000000,"c":12345678,"d":999999999999,"e":1000000000000,"f":null}`), &m)
	for _, k := range []string{"a", "b", "c", "d", "e", "f", "missing"} {
		fmt.Printf("%s => %q\n", k, fmt.Sprintf("%v", m[k]))
	}
}
EOF
(cd "$W" && GOTOOLCHAIN=local go run main.go)
```

Output: `a => "999999"`, `b => "1e+06"`, `c => "1.2345678e+07"`, `d => "9.99999999999e+11"`,
`e => "1e+12"`, `f => "<nil>"`, `missing => "<nil>"`.

### Step 2: the discriminating part, ClickHouse

```bash
CH=$(.claude/skills/diagnostics-and-tooling/scripts/ch-local.sh --path)   # shared cached binary
"$CH" local --query "SELECT version()" </dev/null                          # record it with the result
"$CH" local --query "SELECT v, toDecimal128OrZero(v, 26) FROM (SELECT arrayJoin(['1e+06','1000000',
  '9.99999999999e+11','999999999999','1e+12','1000000000000','<nil>','1.2345678e+07']) AS v) FORMAT TSV" </dev/null
```

Always give `clickhouse local` `</dev/null` (or `--queries-file`), the shared convention with `diagnostics-and-tooling`. A hang on an inherited open stdin was reported earlier; it is UNVERIFIED here (`(sleep 8) | clickhouse local --query 'SELECT 1'` returned at once on 26.2.19.43).

Observed (`clickhouse local` 25.8.2.29; identical on 26.2.9.9 and 26.2.19.43, releases of the 26.2 line the dev image tracks, re-run 2026-10-01):

<!-- evidence-check: off (output of the query above) -->
| `value` string | `decimal_value` |
|---|---|
| `1e+06` | 1000000 |
| `1000000` | 1000000 |
| `1.2345678e+07` | 12345678 |
| `9.99999999999e+11` | 999999999999 |
| `999999999999` | 999999999999 |
| `1e+12` | **0** |
| `1000000000000` | **0** |
| `<nil>` | **0** |

### Verdict and record

- Prediction "0 for `1e+06`" vs observed 1000000: **REFUTED**.
- The boundary controls produced the real finding (ACCEPTED, version-scoped): exponent strings parse. Values >= 1e12 overflow `Decimal(38,26)` to **0**, and so does `"<nil>"`.
- **Scope:** verified on 25.8.2.29, 26.2.9.9 and 26.2.19.43. The dev stack runs `clickhouse/clickhouse-server:26.2-alpine` (`docker-compose.dev.yml:460`); the production ClickHouse version is UNVERIFIED. Re-run on the version you care about before you cite it for production.
- **Lesson:** put boundary controls in every corpus. A refuted hypothesis still leaves the question "what DOES lose data?"
- **Where it was recorded:**
  - the value contract: the `rails-go-parity` skill;
  - the fix options: the `event-accounting-campaign` skill, workstream W2;
  - any ClickHouse schema change: allowed (DECIDED OD-3 (owner, 2026-10-02)); the DDL ships in a paired lago-api PR (change-control N6).
<!-- evidence-check: on -->

---

## Example C: the Rails comment says the ZSET score is "the event timestamp" -> code read REFUTES the comment

No probe is needed. The question is "what does Go write?", and a code read with `path:line` meets the
evidence bar for that.

```bash
grep -n 'event timestamp as score' "$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb"
grep -n 'time.Now().Unix()\|Score:' events-processor/models/stores.go
```

Output:
- `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:11`: "using the event timestamp as score".
- `events-processor/models/stores.go:55` `now := time.Now().Unix()` and `:61` `Score: float64(now)`.

Verdict:
- The score is the processing wall clock (`events-processor/models/stores.go:55`), not the event time. The comment is wrong.
- The consumer only takes members whose score is at least `SUBSCRIPTION_BUCKET_DURATION = 10` s old (`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:14`), and the clock schedules it every 10 s (`$API/clock.rb:211`). So a refresh is enqueued roughly 10–20 s after Go **processed** the event, whatever the event's own timestamp.
- Recorded in the `rails-go-parity` skill. The ZSET contract itself (name, member, bucket) is change-control N6.

---

## Example D: "how many non-release submodule pointer moves since 2025?" -> count by data, not by subject

Two earlier analyses said 14 and 15. Subject filters give unstable numbers:

```bash
git -C "$H" log --since=2025-01-01 --format='%h %s' -- api front | wc -l                                  # 77
git -C "$H" log --since=2025-01-01 --format='%h %s' -- api front | grep -viE 'release|bump' | wc -l        # 20
git -C "$H" log --since=2025-01-01 --format='%h %s' -- api front | grep -viE 'release|bump|v1\.[0-9]+' | wc -l  # 18
```

The discriminating definition is "the commit moved a gitlink onto a commit that carries no lago-api or
lago-front tag". Classify with data:

```bash
T=$(mktemp -d)
git ls-remote --tags https://github.com/getlago/lago-api   > "$T/api-tags.txt"
git ls-remote --tags https://github.com/getlago/lago-front > "$T/front-tags.txt"
for c in $(git -C "$H" log --since=2025-01-01 --format=%h -- api front); do
  bad=""
  for s in api front; do
    now=$(git -C "$H" rev-parse "$c:$s" 2>/dev/null); was=$(git -C "$H" rev-parse "$c~1:$s" 2>/dev/null)
    [ "$now" != "$was" ] && ! grep -q "^$now" "$T/$s-tags.txt" && bad="$bad $s"
  done
  [ -n "$bad" ] && echo "$c untagged:$bad"
done | wc -l        # 15
```

Verdict:
- 15 (as of 2026-10-01). It includes `7251947` "chore(dev): Upgrade Clickhouse version (#749)". The filters above keep it, but a filter that also drops `version` (`grep -viE 'release|bump|version'`, 16 lines) throws it out as if it were a release.
- `12b8101` is one of the 15; `647de3e` (#620) reverted it.
- The rule is change-control N1. The incident narrative belongs to the `failure-archaeology` skill.

---

## Example E: "pinned lago-api still reads `events_enriched_expanded`" -> TRUE AT THE PIN, stale upstream

```bash
git ls-remote https://github.com/getlago/lago-api refs/heads/main      # b5500bc… (2026-10-01)
U=$(mktemp -d)/api.git
git clone -q --bare --filter=blob:none --shallow-since=2026-09-07 https://github.com/getlago/lago-api "$U"
git -C "$U" rev-list --count 591ae9005110346f1c6034ec72ea9046625668cf..main   # 178
git -C "$U" log --format='%h %ad %s' --date=short 591ae9005110346f1c6034ec72ea9046625668cf..main -- db/clickhouse_migrate | grep -i expanded
git -C "$U" log --format='%h %ad %s' --date=short 591ae9005110346f1c6034ec72ea9046625668cf..main -- app/services/events/stores/store_factory.rb
```

Output:
- `6341824 2026-09-24 misc(clickhouse): Drop events_enriched_expanded (#6475)`.
- For `store_factory.rb`: `908fb37 2026-09-10 misc(clickhouse): stop routing to the enriched store (#6368)` and `bffadd8 2026-09-10 refactor(billing): introduce Billing::Context (#6354)`.

Verdict:
- A drift finding read at `$API` (`591ae90`) is true **at the pin**.
- Upstream already removed it (`6341824`). It disappears from this repo when the next release bump moves the `api` gitlink.
- State both facts. Do not call it live in production; that also depends on OPEN DECISION OD-8.

The same commit body says "The events-processor still produces to the expanded topic", but
`d9c32b6` (2026-09-18) had already removed that producer here. A commit message in one repo is not
evidence about another repo's current code.
