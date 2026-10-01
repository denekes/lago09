// cdc-brokers: does the memory-cache CDC consumer still receive updates when
// LAGO_KAFKA_BOOTSTRAP_SERVERS holds a comma-separated broker list?
//
// It drives the REAL cache.NewCache + Cache.ConsumeChanges (six Debezium
// consumers, events-processor/cache/consumer.go startGenericConsumer) against
// kfake, produces one Debezium-unwrapped billable_metrics row, and checks
// whether it becomes visible in the cache. The main consumer splits the list
// (utils.ParseBrokersEnv); the CDC consumers pass the raw string to
// kgo.SeedBrokers.
//
// Relevant only when LAGO_USE_MEMORY_CACHE=true, whose production use is
// OPEN DECISION OD-1 (owner).
//
// Usage (no CGO needed):  cdc-brokers [-wait 4s] [-v]
// Exit codes: 0 ran to completion (read the printed lines), 2 setup error.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/getlago/lago/events-processor/cache"

	"lagoskills/kfakeharness/kfx"
)

func main() {
	wait := flag.Duration("wait", 4*time.Second, "how long to wait for the CDC record to reach the cache")
	verbose := flag.Bool("v", false, "show events-processor logs (default: errors only, to stderr)")
	flag.Parse()
	level := slog.LevelError
	if *verbose {
		level = slog.LevelDebug
	}
	var w io.Writer = os.Stderr
	slog.SetDefault(slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{Level: level})))

	if err := run(*wait); err != nil {
		fmt.Fprintln(os.Stderr, "cdc-brokers: setup error:", err)
		os.Exit(2)
	}
}

func run(wait time.Duration) error {
	const prefix = "p"
	topics := []string{}
	for _, t := range []string{"billable_metrics", "subscriptions", "charges", "billable_metric_filters", "charge_filters", "charge_filter_values"} {
		topics = append(topics, prefix+".public."+t)
	}
	cl, err := kfx.Start(1, topics)
	if err != nil {
		return err
	}
	defer cl.Close()
	addr := cl.Addrs[0]

	for _, brokers := range []string{addr, addr + "," + addr} {
		if err := os.Setenv("LAGO_KAFKA_BOOTSTRAP_SERVERS", brokers); err != nil {
			return err
		}
		ctx, cancel := context.WithCancel(context.Background())
		mc, err := cache.NewCache(cache.CacheConfig{Context: ctx, DebeziumTopicPrefix: prefix})
		if err != nil {
			cancel()
			return err
		}
		consumeErr := mc.ConsumeChanges()

		code := fmt.Sprintf("bm_%d", strings.Count(brokers, ",")+1)
		row := fmt.Sprintf(`{"id":"id-%s","organization_id":"org","code":"%s","aggregation_type":1,"field_name":"v","expression":"","created_at":1,"updated_at":%d,"deleted_at":null}`,
			code, code, time.Now().UnixMicro())
		if err := cl.Produce(context.Background(), topics[0], []byte(row)); err != nil {
			cancel()
			_ = mc.Close()
			return err
		}

		visible := false
		deadline := time.Now().Add(wait)
		for time.Now().Before(deadline) && !visible {
			visible = mc.GetBillableMetric("org", code).Success()
			if !visible {
				time.Sleep(100 * time.Millisecond)
			}
		}
		fmt.Printf("LAGO_KAFKA_BOOTSTRAP_SERVERS brokers=%d comma_joined=%v: ConsumeChanges err=%v, CDC update visible in cache=%v\n",
			strings.Count(brokers, ",")+1, strings.Contains(brokers, ","), consumeErr, visible)
		cancel()
		_ = mc.Close()
	}
	return nil
}
