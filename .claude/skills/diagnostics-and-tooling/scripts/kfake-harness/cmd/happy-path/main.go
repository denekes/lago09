// happy-path: N valid raw events -> the REAL events-processor consumer group
// and processor (in-process) -> count what lands on each output topic, the
// committed offset and the Redis ZSET.
//
// Question it answers: "with no faults, does every raw record end enriched
// (and in-advance when the plan has a pay-in-advance charge), with nothing on
// the DLQ and the committed offset equal to the number of records?"
//
// Usage (CGO env required; kfake-run.sh sets it up):
//
//	happy-path [-n 100] [-partitions 1] [-store cache|db] [-db-url URL] [-timeout 30s] [-cpuprofile FILE] [-v]
//
// -store cache (default) seeds an in-memory badger cache, no Postgres needed.
// -store db reads the fixture tenant from Postgres: load
// ../../fixtures/smoke-schema.sql into a scratch database first (scratch-pg.sh).
//
// Exit codes: 0 all checks passed, 1 a check failed, 2 setup error.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"runtime/pprof"
	"sync"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/config/database"

	"lagoskills/kfakeharness/fixture"
	"lagoskills/kfakeharness/kfx"
	"lagoskills/kfakeharness/pipeline"
)

const (
	raw       = "events-raw"
	enriched  = "events_enriched"
	inAdvance = "events_charged_in_advance"
	dlq       = "events_dead_letter"
)

func main() {
	n := flag.Int("n", 100, "number of raw events to produce")
	partitions := flag.Int("partitions", 1, "partitions of the raw topic (records spread round-robin)")
	store := flag.String("store", "cache", "data source: cache (seeded in memory) or db (Postgres with fixtures/smoke-schema.sql)")
	dbURL := flag.String("db-url", os.Getenv("DATABASE_URL"), "Postgres URL for -store db")
	timeout := flag.Duration("timeout", 30*time.Second, "max wait for the committed offset to reach n")
	verbose := flag.Bool("v", false, "show events-processor logs (default: silenced)")
	cpuprofile := flag.String("cpuprofile", "", "write a CPU profile of the whole run to FILE (read with: go tool pprof -top FILE)")
	flag.Parse()

	if *cpuprofile != "" {
		f, err := os.Create(*cpuprofile)
		if err != nil {
			fmt.Fprintln(os.Stderr, "happy-path:", err)
			os.Exit(2)
		}
		if err := pprof.StartCPUProfile(f); err != nil {
			fmt.Fprintln(os.Stderr, "happy-path:", err)
			os.Exit(2)
		}
	}

	if !*verbose {
		slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	}
	ok, err := run(*n, int32(*partitions), *store, *dbURL, *timeout)
	if *cpuprofile != "" {
		pprof.StopCPUProfile()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "happy-path: setup error:", err)
		os.Exit(2)
	}
	if !ok {
		os.Exit(1)
	}
}

func run(n int, partitions int32, store, dbURL string, timeout time.Duration) (bool, error) {
	ctx := context.Background()
	start := time.Now()

	cl, err := kfx.Start(partitions, []string{raw, enriched, inAdvance, dlq})
	if err != nil {
		return false, err
	}
	defer cl.Close()
	mr, err := miniredis.Run()
	if err != nil {
		return false, err
	}
	defer mr.Close()

	cfg := pipeline.Config{
		Brokers: cl.Addrs, RawTopic: raw, EnrichedTopic: enriched, InAdvanceTopic: inAdvance, DLQTopic: dlq,
		ConsumerGroup: "harness", RedisAddr: mr.Addr(),
	}
	switch store {
	case "cache":
		c, err := cache.NewCache(cache.CacheConfig{Context: ctx})
		if err != nil {
			return false, err
		}
		defer c.Close()
		if err := fixture.SeedCache(c); err != nil {
			return false, err
		}
		cfg.Cache = c
	case "db":
		db, err := database.NewConnection(database.DBConfig{Url: dbURL, MaxConns: 10})
		if err != nil {
			return false, fmt.Errorf("db %s: %w", dbURL, err)
		}
		defer db.Close()
		cfg.DB = db
	default:
		return false, fmt.Errorf("unknown -store %q", store)
	}

	var mu sync.Mutex
	batches, batchRecords := 0, 0
	cfg.Wrap = func(next pipeline.ProcessFunc) pipeline.ProcessFunc {
		return func(ctx context.Context, recs []*kgo.Record) []*kgo.Record {
			out := next(ctx, recs) // real processor.ProcessEvents
			mu.Lock()
			batches++
			batchRecords += len(recs)
			mu.Unlock()
			return out
		}
	}

	p, err := pipeline.New(ctx, cfg)
	if err != nil {
		return false, err
	}
	defer p.Close()

	// Produce N valid events: api_calls (sum of amount, pay-in-advance charge), amount = i.
	prod, err := cl.Client(kgo.RecordPartitioner(kgo.ManualPartitioner()))
	if err != nil {
		return false, err
	}
	ingested := fixture.IngestedNow()
	ts := fmt.Sprintf("%d", time.Now().Unix())
	recs := make([]*kgo.Record, 0, n)
	for i := 1; i <= n; i++ {
		ev := fixture.RawEvent{
			OrganizationID: fixture.Org, ExternalSubscriptionID: fixture.SubExternal,
			TransactionID: fmt.Sprintf("tx_%06d", i), Code: "api_calls",
			Properties: map[string]any{"amount": i}, Timestamp: ts, Source: "harness", IngestedAt: ingested,
		}
		recs = append(recs, &kgo.Record{Topic: raw, Partition: int32(i-1) % partitions, Value: fixture.JSON(ev)})
	}
	if err := prod.ProduceSync(ctx, recs...).FirstErr(); err != nil {
		return false, err
	}
	prod.Close()

	runCtx, stop := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() { p.Run(runCtx); close(done) }()

	// Wait until every partition's committed offset covers what was produced.
	per := map[int32]int64{}
	for i := 0; i < n; i++ {
		per[int32(i)%partitions]++
	}
	committed := int64(0)
	for part, want := range per {
		at, err := cl.WaitCommitted(ctx, p.GroupID, raw, part, want, timeout)
		if err != nil {
			fmt.Println("WARN", err)
		}
		if at > 0 {
			committed += at
		}
	}
	stop()
	<-done

	count := func(topic string) []*kgo.Record {
		rs, err := cl.ReadAll(ctx, topic, 10*time.Second)
		if err != nil {
			fmt.Println("WARN", err)
		}
		return rs
	}
	enr, adv, dead := count(enriched), count(inAdvance), count(dlq)

	sum := 0
	for _, r := range enr {
		var e struct {
			Value *string `json:"value"`
		}
		_ = json.Unmarshal(r.Value, &e)
		var v int
		if e.Value != nil {
			_, _ = fmt.Sscanf(*e.Value, "%d", &v)
		}
		sum += v
	}
	members, _ := mr.ZMembers("subscription_refreshed_v2")

	fmt.Printf("scenario=happy-path store=%s records=%d partitions=%d group=%s\n", store, n, partitions, p.GroupID)
	fmt.Printf("batches seen by ProcessRecords: %d (records %d)\n", batches, batchRecords)
	fmt.Printf("committed offset (sum over partitions): %d\n", committed)
	fmt.Printf("events_enriched: %d  events_charged_in_advance: %d  events_dead_letter: %d\n", len(enr), len(adv), len(dead))
	fmt.Printf("sum(enriched value) = %d (want %d)\n", sum, n*(n+1)/2)
	fmt.Printf("redis ZSET subscription_refreshed_v2 members: %d %v\n", len(members), members)
	fmt.Printf("elapsed: %s\n", time.Since(start).Round(10*time.Millisecond))

	ok := committed == int64(n) && len(enr) == n && len(adv) == n && len(dead) == 0 && sum == n*(n+1)/2 && len(members) >= 1
	if ok {
		fmt.Println("RESULT: PASS (every record enriched + in-advance, 0 DLQ, offsets committed)")
	} else {
		fmt.Println("RESULT: FAIL")
	}
	return ok, nil
}
