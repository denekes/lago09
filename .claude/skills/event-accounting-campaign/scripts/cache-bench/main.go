// cache-bench: memory and warm-up cost of the events-processor memory cache
// (badger in-memory, cache.Cache) for N synthetic subscriptions — the W6
// "memory" metric of the event-accounting-campaign. Production runs
// memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)), so every pod holds
// the whole snapshot in RAM.
//
// It inserts N subscriptions of one organization through the REAL
// cache.SetSubscription (single goroutine, like one snapshot loader), forces a
// GC, then prints insert rate, Go heap in use, process RSS and one
// SearchSubscriptions lookup (a prefix scan) for the middle subscription.
// Subscriptions only: billable metrics, charges and filters add to this.
//
// Usage (via ../run.sh, which builds it into a temp dir):
//
//	run.sh cache-bench [-n 1000000]
//
// Output: one line
//
//	n=<N> insert=<dur> (<rate>/s) heap_inuse_mb=<MB> rss_mb=<MB> lookup_ok=true lookup=<dur>
//
// Exit codes: 0 ok; 1 a cache call failed; 2 bad flag.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

func rssMB() int64 {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return -1
	}
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Fields(l); len(f) >= 2 && f[0] == "VmRSS:" {
			kb, _ := strconv.ParseInt(f[1], 10, 64)
			return kb / 1024
		}
	}
	return -1
}

func main() {
	n := flag.Int("n", 1_000_000, "number of subscriptions to insert")
	flag.Parse()
	if *n <= 0 {
		fmt.Fprintln(os.Stderr, "cache-bench: -n must be > 0")
		os.Exit(2)
	}
	c, err := cache.NewCache(cache.CacheConfig{Context: context.Background()})
	if err != nil {
		fmt.Fprintln(os.Stderr, "cache-bench:", err)
		os.Exit(1)
	}
	defer func() { _ = c.Close() }()

	org := "1a901a90-1a90-1a90-1a90-1a901a901a90"
	start := time.Now()
	for i := 0; i < *n; i++ {
		s := models.Subscription{
			ID: fmt.Sprintf("00000000-0000-0000-0000-%012d", i), OrganizationID: &org,
			ExternalID: fmt.Sprintf("ext_sub_%d", i), PlanID: "2a901a90-1a90-1a90-1a90-1a901a901a90",
			StartedAt: utils.NewNullTime(time.Unix(1700000000, 0)), UpdatedAt: utils.NowNullTime(), CreatedAt: utils.NowNullTime(),
		}
		if r := c.SetSubscription(&s); r.Failure() {
			fmt.Fprintln(os.Stderr, "cache-bench: SetSubscription:", r.Error())
			os.Exit(1)
		}
	}
	elapsed := time.Since(start)
	runtime.GC()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	t := time.Now()
	r := c.SearchSubscriptions(org, fmt.Sprintf("ext_sub_%d", *n/2), time.Now())
	fmt.Printf("n=%d insert=%v (%.0f/s) heap_inuse_mb=%d rss_mb=%d lookup_ok=%v lookup=%v\n",
		*n, elapsed.Round(time.Millisecond), float64(*n)/elapsed.Seconds(), ms.HeapInuse/(1<<20), rssMB(),
		r.Success(), time.Since(t).Round(time.Microsecond))
}
