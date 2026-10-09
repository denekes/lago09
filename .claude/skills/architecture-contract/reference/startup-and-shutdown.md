# Startup contract and graceful shutdown (captured from the real binary)

Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only commits on
top. Captured 2026-10-01 with `startup-contract.sh` (binary built with `ep-env.sh`, run under
`env -i`). Steps S0-S7 need nothing but the binary (S6 needs a reachable Postgres; its 0/6 loads + 6 SQL errors are
what an EMPTY database gives). Steps SK1-SK9 were captured against a disposable in-process broker (franz-go `kfake`,
seeded with the 4 dev topics) and `miniredis`, plus the local Postgres for SK5-SK9; to reproduce them pass
`--broker`/`--redis` pointing at throwaway services (the kfake/miniredis harness lives in `diagnostics-and-tooling`).
Re-run 2026-10-01 → `SUMMARY steps=17 fails=0`. Orphan CDC group counts (row 5c) come from the re-implementation
kit's black-box suite run on the reference binary in cache mode (2026-10-02; `--impl-cmd` = the binary that
`.claude/skills/events-processor-spec/scripts/maintainer/build-go-reference.sh --print-env` names, then
`.claude/skills/events-processor-spec/scripts/run-suite.sh --mode cache --profile compat`; the observed text prints
`other_groups=<n>` per scenario).
Paths below are relative to `events-processor/`.

## 1. Order of operations in `main()` and `StartProcessingEvents`

Startup is only partially fail-fast (invariant I14). `Probe` = the `startup-contract.sh` step id that captures the row
(the numbering here is the one SKILL.md §2 uses).

| # | Step | Code | Failure behaviour | Probe |
|---|---|---|---|---|
| 0 | dynamic loader resolves `libexpression_go.so` | binary is CGO-linked (lago-expression) | `error while loading shared libraries: libexpression_go.so: cannot open shared object file`, exit 127 — before `main` (S0). The image installs the lib in `/usr/lib` | S0 |
| 1 | root ctx + SIGINT/SIGTERM handler goroutine | `main.go:28,43,90-99` | — | — |
| 2 | JSON slog to stdout, attr `service=post_process`; DEBUG when `ENV` unset/`development`, else INFO | `main.go:31-41` | — | — |
| 3 | tracer provider (`TRACING_PROVIDER` → `DD_TRACE_ENABLED` → `OTEL_EXPORTER_OTLP_ENDPOINT` → none) | `main.go:45-51`, `config/tracing/tracer.go:46-60,87-102` | OTel init error returns a typed nil that the `== nil` check at `main.go:46` can never see (golangci SA4023) | — |
| 4 | Sentry init from `SENTRY_DSN`; `sentry.Flush(2s)` deferred | `main.go:53-64` | init error only printed (`fmt.Printf`) | — |
| 5 | memory-cache mode iff `LAGO_USE_MEMORY_CACHE == "true"` (literal) | `main.go:66-81` | `1`, `TRUE`, `yes` do NOT enable it (S7) | S7 |
| 5a | `cache.NewCache` (badger in-memory) | `cache/cache.go:36-53` | panic "Error creating the cache" (`main.go:73`) | — |
| 5b | `LoadInitialSnapshot`: own pgx pool (MaxConns 10) from `DATABASE_URL`, 6 table loaders in parallel, blocking | `cache/cache.go:63-107` | connect failure → panic "Error connecting to the database" (S5) — **before any Kafka check**; a loader SQL error is only logged by gorm and **swallowed** (`cache.go:78-106` return nil) — the process continues with an empty/partial cache (S6) | S5, S6 |
| 5c | `ConsumeChanges`: 6 CDC consumers (`lago_evp_<model>_<uuid>`), each in a NEW group on every start | `cache/cache.go:109-129`, `cache/consumer.go:26-62` | error only if `kgo.NewClient` rejects options; an empty or comma-separated broker string is accepted silently. The consumers start before steps 6-11, so a start that fails there can leave 0-6 orphan `lago_evp_*` groups on a reachable broker (timing-dependent: whichever consumers joined before the panic; kit rule `events-processor-spec` EP-A3, not compared by its suite). A healthy start adds 6 groups, a restart 6 more (kit cache goldens `other_groups=6` for EPC-00, `other_groups=12` for EPC-21, 2026-10-02) | S6 |
| 6 | brokers: `LAGO_KAFKA_BOOTSTRAP_SERVERS` split on `,` | `processors/main_processor.go:103-107` | `panic: brokers not found` (S1); plain `slog.Error` + `panic`, not `LogAndPanic`, so **no Sentry event** | S1 |
| 7 | producers enriched → in-advance → DLQ: topic env required, `kgo.NewClient`, `Ping` | `main_processor.go:55-76,118-131` | `panic: <VAR> variable is required` (S2, SK1, SK2); unreachable broker → `panic: unable to dial: …` (S3); unknown `LAGO_KAFKA_SCRAM_ALGORITHM` → nil `kgo.Opt` → **SIGSEGV in `kgo.validateCfg`, no log line, no Sentry** (S4; `config/kafka/kafka.go:48-64`) | S2, S3, S4, SK1, SK2 |
| 8 | DB mode only (`config.Cache == nil`): `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` (default 200), pgx pool + gorm (gorm pings) | `main_processor.go:133-150` | non-integer → panic "Error converting max connections into integer" (SK3); unreachable → panic "Error connecting to the database" (SK4); empty `DATABASE_URL` falls back to libpq defaults (observed: unix socket `/var/run/postgresql`, user = OS user) | SK3, SK4 |
| 9 | Redis flag store `subscription_refreshed_v2`: `LAGO_REDIS_STORE_DB` int, TLS = `LAGO_REDIS_STORE_TLS` else `ENV=="production"`, `Ping` | `main_processor.go:78-100,152-156`, `config/redis/redis.go:30-66` | panic "Error connecting to the flag store" (SK5 bad DB int, SK6 unreachable: go-redis prints 4 non-JSON `redis: … pool.go:419: … failed to dial after 5 attempts` lines first); `ENV=production` against a plaintext Redis → `panic: EOF` (SK7). Empty URL → go-redis default `localhost:6379` (observed dialing `127.0.0.1:6379`) | SK5, SK6, SK7 |
| 10 | processor wiring | `main_processor.go:158-166` | — | — |
| 11 | consumer group `<group>_<topic>`, options, `Ping` | `main_processor.go:168-179`, `config/kafka/consumer.go:227-259` | panic "Error starting the event consumer". Empty topic/group are NOT validated: group `_`, process idles (SK9). A missing topic is not fatal: franz-go logs `UNKNOWN_TOPIC_OR_PARTITION` at INFO and waits (SK8) | SK8, SK9 |
| 12 | `Starting event consumer`, `cg.Start(ctx)` blocks until ctx canceled | `main_processor.go:181-183` | — | SK8 |

Every `utils.LogAndPanic` (`utils/error_tracker.go:30-34`) logs `{"level":"ERROR","msg":<message>,"error":<err>}`,
captures to Sentry, then `panic(err.Error())` — so the **panic text is the underlying error, the log `msg` is the
step name**. The deferred `sentry.Flush` in `main` runs during the panic unwind.

## 2. Captured outputs (exit 2 = Go panic; timestamps removed)

```text
S0  /…/ep: error while loading shared libraries: libexpression_go.so: cannot open shared object file: No such file or directory   (exit 127)
S1  {"level":"ERROR","msg":"brokers not found","service":"post_process"}
    panic: brokers not found
S2  {"level":"ERROR","msg":"failed to initialize enriched events producer","service":"post_process","error":"LAGO_KAFKA_ENRICHED_EVENTS_TOPIC variable is required"}
    panic: LAGO_KAFKA_ENRICHED_EVENTS_TOPIC variable is required
S3  {"level":"WARN","msg":"unable to open connection to broker",…,"component":"kafka","addr":"127.0.0.1:1","broker":"seed_0",…}
    {"level":"ERROR","msg":"failed to initialize enriched events producer",…,"error":"unable to dial: dial tcp 127.0.0.1:1: connect: connection refused"}
    panic: unable to dial: dial tcp 127.0.0.1:1: connect: connection refused
S4  panic: runtime error: invalid memory address or nil pointer dereference
    [signal SIGSEGV: segmentation violation …]
    github.com/twmb/franz-go/pkg/kgo.validateCfg(…) … config/kafka.NewKafkaClient … kafka.go:71
S5  {"level":"ERROR","msg":"failed to initialize database, got error failed to connect to `user=lago database=lago`: …","component":"db"}
    {"level":"ERROR","msg":"Error connecting to the database",…}
    panic: failed to connect to `user=lago database=lago`: …   (stack: cache.(*Cache).LoadInitialSnapshot)
S6  6× {"level":"INFO","msg":"Starting snapshot load","pkg":"cache","model":"<table>"}
    6× {"level":"ERROR","msg":"ERROR: relation \"<table>\" does not exist (SQLSTATE 42P01)","component":"db",…}   (empty DB)
    0× "Completed snapshot load"
    6× {"level":"INFO","msg":"Starting consumer","pkg":"cache","model":"<table>","topic":".public.<table>","group_id":"lago_evp_<table>_<uuid>"}
    panic: brokers not found
S7  panic: brokers not found     (LAGO_USE_MEMORY_CACHE=1: no snapshot started)
SK1 panic: LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC variable is required   (msg "failed to initialize events charged in advance producer")
SK2 panic: LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC variable is required          (msg "failed to initialize events dead letter queue producer")
SK3 panic: strconv.Atoi: parsing "abc": invalid syntax                        (msg "Error converting max connections into integer")
SK4 panic: failed to connect to `user=lago database=lago`: …                  (msg "Error connecting to the database"; stack: processors.StartProcessingEvents)
SK5 panic: strconv.Atoi: parsing "x": invalid syntax                          (msg "Error connecting to the flag store")
SK6 redis: <date> pool.go:419: redis: connection pool: failed to dial after 5 attempts: dial tcp 127.0.0.1:1: connect: connection refused   (×4)
    panic: dial tcp 127.0.0.1:1: connect: connection refused                  (msg "Error connecting to the flag store")
SK7 redis: <date> pool.go:419: redis: connection pool: failed to dial after 5 attempts: EOF   (×4)
    panic: EOF                                                                (ENV=production ⇒ TLS to a plaintext Redis)
SK8 {"level":"INFO","msg":"Starting event consumer",…}
    {"level":"INFO","msg":"metadata update triggered",…,"why":"re-updating due to inner errors: UNKNOWN_TOPIC_OR_PARTITION{startup-contract-probe-…}"}
    … SIGTERM … "Gracefully shutting down consumer group" … "Consumer group shutdown is complete" … "Event processor stopped"
SK9 {"level":"WARN","msg":"metadata response contained nil topic name even though we did not request with topic IDs, skipping",…}
    {"level":"INFO","msg":"Starting event consumer",…}   … on SIGTERM: "tried to leave group but we have no member ID yet" … "group":"_"
```

## 3. Healthy start and SIGTERM (real topic `events-raw`, group `probe`)

Not a script step (SK8 uses a random, missing topic, so it never gets an assignment). Re-captured 2026-10-01 by
running the built binary directly under `env -i` against a kfake cluster seeded with topic `events-raw` (1
partition) plus miniredis and the local Postgres, `LAGO_KAFKA_RAW_EVENTS_TOPIC=events-raw`,
`LAGO_KAFKA_CONSUMER_GROUP=probe`, `timeout -s TERM 6`. Subset of lines (timestamps and `service` removed; join/sync/metadata chatter omitted):

```text
{"msg":"Starting event consumer"}
{"msg":"beginning to manage the group lifecycle","component":"kafka","group":"probe_events-raw"}
{"msg":"joined, balancing group",…,"balance_protocol":"cooperative-sticky","leader":true}
{"msg":"new group session begun",…,"added":{"events-raw":[0]}}
{"msg":"Starting consume for topic events-raw partition 0\n","kafka-topic-consumer":"events-raw"}
{"msg":"assigning partitions",…,"why":"newly fetched offsets for group probe_events-raw","input":{"events-raw":{"0":{"At":-2,…}}}}   ← -2 = earliest
… SIGTERM …
{"msg":"Received shutdown signal","signal":"terminated"}
{"msg":"Gracefully shutting down consumer group","kafka-topic-consumer":"events-raw"}
{"msg":"Shuting down partion consumer","topic":"events-raw","partition":0}
{"msg":"partition consumer quit"}
{"msg":"Closing consume for topic events-raw partition 0\n"}
{"msg":"assigning partitions",…,"why":"invalidating all assignments in LeaveGroup"}
{"msg":"waiting for work to finish topic events-raw partition 0\n"}
{"msg":"leaving group",…,"group":"probe_events-raw"}
{"msg":"Consumer group shutdown is complete"}
{"msg":"Event processor stopped"}
```

## 4. Shutdown sequence (code)

1. SIGINT/SIGTERM → `cancel()` of the root ctx (`main.go:94-98`).
2. The poll goroutine returns (`config/kafka/consumer.go:155-158`, or `PollRecords` returns a context error, `:174-188`).
3. `Start` → `gracefulShutdown` (`consumer.go:261-272,207-225`): close every partition consumer's `quit`, wait for its
   `done`. A partition consumer only checks `quit` between batches (`consume`, `:57-72`), and the batch runs on
   `context.Background()` (`:83`), so **the in-flight batch (up to all records of that partition in the last poll)
   finishes and commits** before shutdown proceeds. If it takes longer than the orchestrator's grace period, SIGKILL
   leaves it uncommitted → redelivery (duplicates, absorbed only where downstream dedup is on: invariant I12, CONDITIONAL).
4. `client.Close()` leaves the group (LeaveGroup triggers the revoke callback = `lost`, harmless after step 3).
5. `StartProcessingEvents` returns → deferred `flagger.Close()` (`main_processor.go:156`), `db.Close()` (`:149`);
   then in `main`: `memCache.Close()` (`main.go:75`), `sentry.Flush(2s)` (`:64`), `tracerProvider.Stop()` (`:49`),
   `cancel()` (`:29`).
6. Not done: `Cache.Wait()` (`cache/cache.go:59-61`) is never called, so badger can close while a CDC goroutine is
   mid-record (impact UNVERIFIED).
