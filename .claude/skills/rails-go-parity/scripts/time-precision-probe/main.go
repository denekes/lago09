// time-precision-probe: measures how the REAL events-processor time helpers
// (utils.ToTime, utils.ToFloat64Timestamp, utils.CustomTime) treat the timestamp
// strings Rails actually sends, and counts millisecond mismatches.
//
// Usage (from .claude/skills/rails-go-parity/scripts):
//
//	go run ./time-precision-probe                    # base second 1741007009
//	go run ./time-precision-probe -base 1700000000   # another base second
//	go run ./time-precision-probe -scan 20           # also scan 20 more base seconds
//	go run ./time-precision-probe -fail-on-mismatch  # exit 1 if ToTime(string) mismatches > 0
//
// Input corpus: "<base>.<ms>" for ms in 0..999. That is the shape of
//   - Rails KafkaProducerService: timestamp.to_f.to_s      (ms-precision events)
//   - Rails ReEnrichSubscriptionEventsService: strftime("%s.%3N")
//
// The expected instant is time.Unix(base, ms*1e6) in UTC: what Rails (BigDecimal) and
// ClickHouse (toDateTime64(string, 3)) use.
//
// Exit codes: 0 = report printed; 1 = -fail-on-mismatch and ToTime(string) mismatches > 0;
// 2 = bad flags, or a corpus string that utils.ToTime/ToFloat64Timestamp failed to parse.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/getlago/lago/events-processor/utils"
)

type counts struct {
	toTimeStr   int // utils.ToTime(string) != expected instant
	toTimeEarly int // ... of which land exactly 1 ms early
	toFloatStr  int // JSON text of utils.ToFloat64Timestamp(string) != "<base>.<ms>" at ms precision
	toTimeNum   int // utils.ToTime(float64) (a JSON number timestamp) != expected
	firstMiss   []string
}

func expectedMs(text string) (string, bool) {
	// Reduce a decimal JSON number text to "<int>.<3 digits>" (truncate, like CH DateTime64(3)).
	if strings.ContainsAny(text, "eE") {
		return "", false
	}
	intPart, frac, _ := strings.Cut(text, ".")
	frac = (frac + "000")[:3]
	return intPart + "." + frac, true
}

func measure(base int64, keepExamples int) counts {
	var c counts
	for ms := int64(0); ms < 1000; ms++ {
		in := fmt.Sprintf("%d.%03d", base, ms)
		want := time.Unix(base, ms*int64(time.Millisecond)).UTC()

		r := utils.ToTime(in)
		if r.Failure() {
			fmt.Fprintf(os.Stderr, "ToTime(%q) failed: %v\n", in, r.Error())
			os.Exit(2)
		}
		got := r.Value()
		if !got.Equal(want) {
			c.toTimeStr++
			if want.Sub(got) == time.Millisecond {
				c.toTimeEarly++
			}
			if len(c.firstMiss) < keepExamples {
				c.firstMiss = append(c.firstMiss, fmt.Sprintf("%s -> %s", in, got.Format("15:04:05.000Z07:00")))
			}
		}

		f := utils.ToFloat64Timestamp(in)
		if f.Failure() {
			fmt.Fprintf(os.Stderr, "ToFloat64Timestamp(%q) failed: %v\n", in, f.Error())
			os.Exit(2)
		}
		b, _ := json.Marshal(f.Value()) // what EnrichedEvent.timestamp looks like on the wire
		if norm, ok := expectedMs(string(b)); !ok || norm != in {
			c.toFloatStr++
		}

		var num float64
		_ = json.Unmarshal([]byte(in), &num) // a producer sending the timestamp as a JSON number
		rn := utils.ToTime(num)
		if rn.Failure() || !rn.Value().Equal(want) {
			c.toTimeNum++
		}
	}
	return c
}

func main() {
	base := flag.Int64("base", 1741007009, "base unix second (default = 2025-03-03T13:03:29Z)")
	scan := flag.Int("scan", 0, "also report ToTime(string) mismatch counts for the next N base seconds")
	failOn := flag.Bool("fail-on-mismatch", false, "exit 1 if ToTime(string) mismatches > 0 at -base")
	flag.Parse()

	c := measure(*base, 3)
	fmt.Printf("base=%d (%s), corpus=1000 strings \"<base>.<ms>\" ms=0..999\n",
		*base, time.Unix(*base, 0).UTC().Format(time.RFC3339))
	fmt.Printf("ToTime(string) mismatches: %d/1000 (exactly 1 ms early: %d)\n", c.toTimeStr, c.toTimeEarly)
	fmt.Printf("ToFloat64Timestamp(string) JSON text != input at ms precision: %d/1000\n", c.toFloatStr)
	fmt.Printf("ToTime(float64 JSON number) mismatches: %d/1000\n", c.toTimeNum)
	if len(c.firstMiss) > 0 {
		fmt.Printf("first ToTime mismatches: %s\n", strings.Join(c.firstMiss, "; "))
	}

	if *scan > 0 {
		total, minM, maxM := 0, 1001, -1
		for i := int64(1); i <= int64(*scan); i++ {
			m := measure(*base+i, 0).toTimeStr
			total += m
			minM = min(minM, m)
			maxM = max(maxM, m)
		}
		fmt.Printf("scan of next %d base seconds: ToTime(string) mismatches min=%d max=%d mean=%.1f per 1000\n",
			*scan, minM, maxM, float64(total)/float64(*scan))
	}

	// RFC3339 branch: accepted since 76c1b3b, returned without UTC normalization or ms truncation.
	rfc := "2025-03-03T15:03:29.123456+02:00"
	r := utils.ToTime(rfc)
	if r.Success() {
		t := r.Value()
		_, off := t.Zone()
		fmt.Printf("ToTime(%q) = %s | utc_offset_s=%d | sub-ms_ns=%d (numeric branches return UTC, ms-truncated)\n",
			rfc, t.Format(time.RFC3339Nano), off, t.Nanosecond()%int(time.Millisecond))
	}

	// ingested_at as Rails sends it (iso8601(3) minus the trailing Z) and as the DLQ re-emits it.
	var ct utils.CustomTime
	railsIngested := `"2025-03-03T13:03:30.456"`
	if err := json.Unmarshal([]byte(railsIngested), &ct); err != nil {
		fmt.Printf("CustomTime unmarshal %s: error %v\n", railsIngested, err)
	} else {
		out, _ := json.Marshal(ct)
		fmt.Printf("ingested_at %s -> parsed %s -> re-marshalled (DLQ) %s\n",
			railsIngested, ct.Time().Format(time.RFC3339Nano), out)
	}
	var zero utils.CustomTime
	zout, _ := json.Marshal(zero)
	fmt.Printf("missing ingested_at -> zero time; re-marshalled (DLQ) %s; time.Since(zero) > 12h = %t\n",
		zout, time.Since(zero.Time()) > 12*time.Hour)

	if *failOn && c.toTimeStr > 0 {
		os.Exit(1)
	}
}
