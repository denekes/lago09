# kfake technique: in-process Kafka driving the REAL events-processor consumer

Read when you need to observe what the real consumer group, commit logic or processor does with
specific records, or when you build a new scenario (including the event-accounting-campaign ledger).
Facts verified 2026-10-01 unless marked. Code facts as of 5308258 (events-processor tree 83e012866f29);
the working branch may carry skills-only commits on top.

## 1. Why kfake

- events-processor's commit path (`events-processor/config/kafka/consumer.go:82` `processRecordsAndCommit`,
  poll loop `:167` `pollRecords` -> `:168` `PollRecords(ctx, 10000)`) and `ProcessEvents`
  (`events-processor/processors/events_processor/processor.go:32`) have 0% unit-test coverage; only the
  pure helper `findMaxCommitableRecord` (`consumer.go:278`) is unit-tested (100%). VERIFIED 2026-10-01 with
  `go test -coverprofile` + `go tool cover -func` on the packages with tests (policy: `validation-and-qa`).
  Unit tests with fakes cannot show rebalance, commit or redelivery behaviour.
- `kfake` (`github.com/twmb/franz-go/pkg/kfake`) is a Kafka broker written in Go by the franz-go author.
  It runs in-process, listens on real `127.0.0.1` TCP ports, supports consumer groups and offset
  commits, and lets you intercept any request (`Cluster.Control`, kfake `cluster.go:463`).
- So a probe can call the repo's own `kafka.NewConsumerGroup` and `events_processor.NewEventProcessor`
  (imported through a `replace` directive) and observe real commits. No Docker, no Redpanda.
- change-control N7 requires a test that drives `processRecordsAndCommit` before any delivery-semantics
  change (the target contract is ADR-001, DECIDED OD-2 (owner, 2026-10-02); text in
  `event-accounting-campaign` `reference/delivery-options.md`). This module is the building block for
  that test; the fault-matrix ledger itself belongs to `event-accounting-campaign`.

## 2. The version trap (verified 2026-10-01)

kfake has **no tags**; you depend on a pseudo-version. events-processor pins franz-go **v1.20.5**
(`events-processor/go.mod:18`).

| What you do | What happens |
|---|---|
| `go get github.com/twmb/franz-go/pkg/kfake@latest` | resolves `v0.0.0-20260927204940-b5a45ccfdf7e`, which requires franz-go v1.21.7 and `go 1.26.0`. Go upgrades franz-go to v1.21.7 and kmsg to v1.14.0 (plus klauspost/compress, pierrec/lz4 and the `go` line to 1.26.0; one `go: upgraded` line each, easy to miss) and switches to a go1.26.x toolchain: **you are now testing events-processor against a franz-go it does not ship with**. |
| same, plus `replace github.com/twmb/franz-go => github.com/twmb/franz-go v1.20.5` | compile error: `18_api_versions.go:122:5: vs.EachSupportedFeature undefined (type *kversion.Versions has no field or method EachSupportedFeature)` (also `EachFinalizedFeature`). |
| `go get github.com/twmb/franz-go/pkg/kfake@latest github.com/twmb/franz-go@v1.20.5` (both in one command) | refused, exit 1: `kfake@latest (v0.0.0-20260927204940-b5a45ccfdf7e) requires github.com/twmb/franz-go@v1.21.7, not github.com/twmb/franz-go@v1.20.5`. All three behaviours are current (re-run 2026-10-01). |
| pin `github.com/twmb/franz-go/pkg/kfake v0.0.0-20251123185109-2b5c574e9ddd` (franz-go commit `2b5c574e9ddd`) | its go.mod requires franz-go v1.20.4, kadm v1.17.1, kmsg v1.12.0, `go 1.24.0`; minimal version selection keeps franz-go **v1.20.5**. No replace needed. **This is what `scripts/kfake-harness/go.mod` pins.** |

Reproduce the failure (throwaway dir, ~25 s):
```bash
d=$(mktemp -d) && cd "$d" && printf 'module t\n\ngo 1.25.0\n\nrequire github.com/twmb/franz-go v1.20.5\n\nreplace github.com/twmb/franz-go => github.com/twmb/franz-go v1.20.5\n' > go.mod \
 && printf 'package main\nimport "github.com/twmb/franz-go/pkg/kfake"\nfunc main(){ c,_ := kfake.NewCluster(); c.Close() }\n' > main.go \
 && go get github.com/twmb/franz-go/pkg/kfake@latest && go build ./... ; cd - >/dev/null; rm -rf "$d"
# expect: go: upgraded github.com/twmb/franz-go v1.20.5 => v1.21.7
#         .../kfake@v0.0.0-20260927204940-b5a45ccfdf7e/18_api_versions.go:122:5: vs.EachSupportedFeature undefined ...
```
Check the pin of the harness at any time: `scripts/kfake-run.sh --check` prints
`franz-go: events-processor=v1.20.5 harness=v1.20.5` and fails (exit 5) if they differ.

When events-processor bumps franz-go (done by hand so far: v1.20.3 -> v1.20.5 inside the Datadog tracing PR
`475761d` (#633)), re-pin kfake: pick the newest kfake
pseudo-version whose go.mod requires a franz-go <= the new events-processor version
(`go list -m -json github.com/twmb/franz-go/pkg/kfake@<commit>` then read its `GoMod` file), run
`go mod tidy` in `scripts/kfake-harness/`, then `kfake-run.sh --check` and both demo scenarios, then the
dependent campaign module (section 7).

## 3. Module layout (`scripts/kfake-harness/`, module `lagoskills/kfakeharness`)

| Path | CGO? | What it is |
|---|---|---|
| `go.mod` | – | `go 1.25.0`; pins kfake + kadm; `replace github.com/getlago/lago/events-processor => ../../../../../events-processor` (five `..`: kfake-harness → scripts → diagnostics-and-tooling → skills → .claude → repo root) |
| `kfx/kfx.go` | no | `Start(partitions, topics, opts...)`, `(*Cluster).Client`, `Produce`, `ReadAll` (to high watermark), `Committed`, `WaitCommitted`, `Groups`. Embeds `*kfake.Cluster`, so `Control`/`ControlKey` are available for fault injection. No events-processor dependency. |
| `fixture/fixture.go` | no | One deterministic tenant (org `11111111-…`, plan `22222222-…`, BMs `api_calls` sum/`count_calls`/`expr_metric`, sub `sub_ext_1` started `2025-01-01 00:00:00.000500`, pay-in-advance charge on `api_calls`). `SeedCache` writes it into a memory cache; identical rows live in `scripts/fixtures/smoke-schema.sql` for DB mode. `RawEvent`, `IngestedNow`, `JSON` build raw-topic payloads. |
| `pipeline/pipeline.go` | **yes** | `New(ctx, Config)` wires real producers, Redis flag store, `EventProcessor` and `kafka.NewConsumerGroup` like `events-processor/processors/main_processor.go:102` `StartProcessingEvents` (minus env parsing, SASL/TLS, Kafka client tracer hooks and panics; see s.6). `Config.Wrap` wraps `ProcessEvents` for observation or fault injection. `Run(ctx)` = real `cg.Start` incl. graceful shutdown. |
| `cmd/happy-path` | yes | demo 1 (below) |
| `cmd/cdc-brokers` | no | demo 2 (below) |
| `cmd/smoke` | no | drives a BUILT binary; used by `smoke-binary.sh` |

Build outputs: `kfake-run.sh` builds each scenario to `$LAGO_SKILLS_CACHE/kfake-harness-bin/<GOFLAGS hash>/<name>`
(a persistent path, so `go build` skips the relink when nothing changed); `smoke-binary.sh` builds into a
mktemp dir. Nothing is written in the skill dir. If you build by hand, use `go build -o "$TMPDIR/..."`.

## 4. Demo scenarios (run from repo root)

### happy-path
Question: with no faults, does every raw record end enriched (+ in-advance when the plan has a
pay-in-advance charge), with nothing on the DLQ and the committed offset equal to N?
```bash
.claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path            # cache store, N=100
.claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path -n 5000 -partitions 3
URL=$(.claude/skills/diagnostics-and-tooling/scripts/scratch-pg.sh create hp_db .claude/skills/diagnostics-and-tooling/scripts/fixtures/smoke-schema.sql)
.claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path -store db -db-url "$URL"
.claude/skills/diagnostics-and-tooling/scripts/scratch-pg.sh drop hp_db
```
Expected today (cache store, N=100; the ZSET bucket number varies with the clock):
```
scenario=happy-path store=cache records=100 partitions=1 group=harness_events-raw
batches seen by ProcessRecords: 1 (records 100)
committed offset (sum over partitions): 100
events_enriched: 100  events_charged_in_advance: 100  events_dead_letter: 0
sum(enriched value) = 5050 (want 5050)
redis ZSET subscription_refreshed_v2 members: 1 [11111111-1111-1111-1111-111111111111:bbbbbbbb-0000-0000-0000-000000000001|<bucket>]
elapsed: 130ms
RESULT: PASS (every record enriched + in-advance, 0 DLQ, offsets committed)
```
`-store db` prints the same counts (elapsed ~160 ms). `-n 5000 -partitions 3`: 3 batches, committed 5000,
sum 12502500, PASS. `-n 50000 -partitions 4`: 8 batches, PASS, elapsed 2.9-3.5 s (kfake and miniredis
share the process: use it for relative comparisons only, never as a production throughput figure).
Exit codes: 0 PASS, 1 FAIL, 2 setup error; `kfake-run.sh` passes them through (VERIFIED: `-store bogus`
-> 2, `-n 10 -timeout 1ns` -> `RESULT: FAIL`, 1). Flags: `-n -partitions -store -db-url -timeout -cpuprofile -v`.

### cdc-brokers
Question: do the memory-cache CDC consumers receive updates when `LAGO_KAFKA_BOOTSTRAP_SERVERS` holds
a comma-separated list? (The main consumer splits it with `utils.ParseBrokersEnv`, `events-processor/utils/env.go:22`;
the CDC consumer passes the raw string to `kgo.SeedBrokers`, `events-processor/cache/consumer.go:28-31`.)
Production-relevant: production runs memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)); whether
production sets a broker list is OPEN DECISION OD-1b (owner).
```bash
.claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh cdc-brokers
```
Expected today (~4-6 s; the negative case waits `-wait 4s`):
```
LAGO_KAFKA_BOOTSTRAP_SERVERS brokers=1 comma_joined=false: ConsumeChanges err=<nil>, CDC update visible in cache=true
LAGO_KAFKA_BOOTSTRAP_SERVERS brokers=2 comma_joined=true: ConsumeChanges err=<nil>, CDC update visible in cache=false
```
No ERROR log line is printed in the failing case (that silence is part of the measurement).
Meaning: `architecture-contract` WP10 (as-is weak point); the variable: `config-and-flags`. Fixing it:
`event-accounting-campaign` W6-2 (DEFAULT APPLIED OD-20: W6 owns memory-cache hardening; the owner may
reassign it); its acceptance flips the second line to `visible in cache=true`.

## 5. Writing a new scenario (template)

1. `mkdir scripts/kfake-harness/cmd/<name>` and add `main.go` (`package main`). Header comment: the
   question it answers, usage, exit codes.
2. Start infra: `cl, _ := kfx.Start(1, []string{"events-raw","events_enriched","events_charged_in_advance","events_dead_letter"})`,
   `mr, _ := miniredis.Run()`.
3. Data source: memory cache (`cache.NewCache` + `fixture.SeedCache`) or DB
   (`database.NewConnection` on a `scratch-pg.sh` database loaded with `fixtures/smoke-schema.sql`).
4. `p, _ := pipeline.New(ctx, pipeline.Config{..., Wrap: myWrap})`; produce with `cl.Produce` or a
   `cl.Client(kgo.RecordPartitioner(kgo.ManualPartitioner()))` for chosen partitions; `go p.Run(runCtx)`.
5. Wait on a measurable condition, never on `time.Sleep` alone: `cl.WaitCommitted(ctx, p.GroupID, topic, partition, want, timeout)`.
6. Stop (`cancel()`; wait for `Run` to return), then read outputs with `cl.ReadAll` and Redis with `mr.ZMembers`.
7. Print one line per fact and a final `RESULT:` line; exit 0/1/2.
8. Run `kfake-run.sh --check` (vet + gofmt + franz-go pin) and `GOFLAGS=-race kfake-run.sh <name>`.
9. Record the command and its expected output in `reference/harness-catalogue.md`.

Fault-injection hooks (building blocks only; the matrix is `event-accounting-campaign`'s):
- **Processor-level**: `Config.Wrap` receives the real `ProcessEvents`. Returning fewer records than
  given reproduces the retryable-failure path (`events-processor/processors/events_processor/processor.go:74-78` returns
  without marking the record). A panic in the wrapper reproduces a crash mid-batch.
- **Broker-level**: `cl.Control(func(req kmsg.Request) (kmsg.Response, error, bool) {...})` (or
  `ControlKey(int16(kmsg.OffsetCommit), ...)`) to fail produce, fetch or commit requests.
  A control function is dropped once it handles a request (returns `handled=true`) unless it calls
  `cl.KeepControl()`; return `handled=false` to let the cluster serve the request normally (kfake
  `cluster.go:443-463` doc comment, `ControlKey` `:488`, `KeepControl` `:506`).
- **Restart**: run a second `pipeline.New` + `Run` with the same `ConsumerGroup` prefix after the
  first one returns; it resumes from the committed offset. VERIFIED with a throwaway external module:
  `consumer #1: offsets seen 0..9 (10 records), committed=10` then
  `consumer #2 (restart, same group): offsets seen 10..14 (5 records), committed=15`.

## 6. Harness vs production: known differences

| Aspect | Production binary | Harness | Consequence |
|---|---|---|---|
| Tracer | `events-processor/main.go:45-50` calls `tracing.InitTracer` before any goroutine (`InitTracerProvider` always returns a provider, `tracer.go:46-61`) | `pipeline.New` calls `tracing.InitTracer(&tracing.EmptyTracerProvider{})` | Without that call, `-race` reports a data race in `tracing.GetTracer` (`events-processor/config/tracing/tracer.go:75-80`, unsynchronised lazy init) as soon as two partitions run. VERIFIED 2026-10-01: harness copy without the call -> `Found 1 data race(s)` at `tracer.go:76`/`:77`, exit 66 (2 of 2 runs); with it -> race-clean (5000 records x 4 partitions x 2, DB mode 3000 x 3, cdc-brokers). Production is not affected because main.go initialises first. |
| Env parsing, startup panics, Sentry, `ENV` log level | yes | no | Use `smoke-binary.sh` for startup behaviour. |
| SASL/TLS, several brokers | per env | plaintext, 1 broker | kfake has `NumBrokers`, `EnableSASL`, `Superuser` and `TLS` options (kfake `config.go:45,98,107,113` respectively); not exercised here (UNVERIFIED with events-processor). |
| Topics | pre-created by `scripts/create-topics.sh` in dev | seeded by `kfx.Start` | Auto-creation is off in kfake unless `kfake.AllowAutoTopicCreation()`. |
| Throughput | real network, real Postgres/Redis | in-process | relative numbers only |

## 7. Handoff notes for event-accounting-campaign

- **DEPENDENT (structural build dependency).** `event-accounting-campaign/scripts/go.mod` requires
  `lagoskills/kfakeharness v0.0.0` through
  `replace lagoskills/kfakeharness => ../../diagnostics-and-tooling/scripts/kfake-harness`, its
  `accounting-probe` imports `kfx`, `fixture` and `pipeline`, its `value-corpus` imports `fixture`. Renaming the module
  `lagoskills/kfakeharness`, moving `scripts/kfake-harness/` or changing the exported API of
  `kfx`/`fixture`/`pipeline` breaks them. After any such change, in the same PR run
  `.claude/skills/event-accounting-campaign/scripts/run.sh --check` (go vet + gofmt + franz-go pin of that
  module; expect `run.sh: check OK`) and the campaign's `scoreboard.sh`. After a kfake re-pin here, also run
  `go mod tidy` in that module (its go.mod lists the same kfake pseudo-version as `// indirect`).
- Reuse `kfx`, `fixture` and `pipeline` as they are; a new probe goes in a scenario `cmd/<name>` here or,
  like the campaign, in its own module with `require lagoskills/kfakeharness v0.0.0` plus TWO replace directives:
  `replace lagoskills/kfakeharness => <relative path to scripts/kfake-harness>` and
  `replace github.com/getlago/lago/events-processor => <relative path to events-processor>`
  (Go ignores `replace` directives of dependencies, so the harness's own replace is not inherited),
  then `go mod tidy`. VERIFIED 2026-10-01: such a module builds, and `go list -m` shows franz-go
  v1.20.5 and kfake `v0.0.0-20251123185109-2b5c574e9ddd` inherited through MVS.
- Every scenario must keep production's tracer initialisation (section 6) or `-race` results are noise.
- Raw events carry no key (lago-api `build_message` sets only topic and payload,
  `$API/app/services/events/kafka_producer_service.rb:29-34`), so `findMaxCommitableRecord` keys are
  `"-<offset>"`; give records keys only if you are deliberately testing keyed input.
