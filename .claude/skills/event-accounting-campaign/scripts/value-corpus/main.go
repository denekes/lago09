// value-corpus: W2 value fidelity and W3 time precision gate metrics.
//
// Mode "value": every row of corpus.tsv becomes a raw-topic event whose
// properties.amount is the row's JSON text. The event goes through the REAL
// code path: json.Unmarshal into models.Event (as ProcessEvents does,
// events-processor/processors/events_processor/processor.go:50) and
// EventEnrichmentService.EnrichEvent (memory cache seeded with the
// diagnostics-and-tooling fixture tenant; BM api_calls = sum of "amount").
// For each row it prints:
//
//	go_value      the `value` string events-processor produces today
//	want_value    CANDIDATE faithful string (corpus.tsv; Rails-derived)
//	go_decimal    go_value parsed as an exact decimal, unparsable -> 0 (what an
//	              unbounded toDecimal...OrZero would read)
//	ch_decimal    go_decimal through ClickHouse Decimal(38,26): |x| >= 1e12 -> 0
//	              (emulated; cross-check against a real binary with -ch-bin)
//	want_decimal  what lago-api's own enrichment computes (corpus.tsv; -ruby re-derives it)
//
// Mode "time": utils.ToTime over "1741007009.<ms>" for ms 0..999, counting
// results whose millisecond differs from the input; plus whether an RFC3339
// timestamp with an offset comes back normalised to UTC and truncated to ms.
//
// Usage (CGO env required for mode value; use ../run.sh value-corpus [flags]):
//
//	value-corpus [-mode all|value|time] [-ruby] [-ch-bin PATH] [-fail-on-mismatch] [-v]
//
// Last line: SUMMARY corpus_rows=.. value_mismatches=.. go_decimal_mismatches=..
// ch_zeroed=.. end_to_end_decimal_mismatches=.. totime_mismatches=../1000 rfc3339_utc_ms=true|false
//
// Exit codes: 0 done (mismatches are data); 1 -fail-on-mismatch and any mismatch;
// 2 setup error (corpus unreadable, cache, ruby or clickhouse failure).
package main

import (
	"bufio"
	_ "embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/processors/events_processor"
	"github.com/getlago/lago/events-processor/utils"

	"lagoskills/kfakeharness/fixture"
)

//go:embed corpus.tsv
var corpusTSV string

//go:embed rails_semantics.rb
var railsRB string

type entry struct {
	id, jsonText, wantValue, wantDecimal, note string
}

func parseCorpus() ([]entry, error) {
	var out []entry
	for i, line := range strings.Split(corpusTSV, "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 4 {
			return nil, fmt.Errorf("corpus.tsv line %d: want >= 4 tab-separated fields, got %d", i+1, len(f))
		}
		e := entry{id: f[0], jsonText: f[1], wantValue: f[2], wantDecimal: f[3]}
		if len(f) > 4 {
			e.note = f[4]
		}
		out = append(out, e)
	}
	return out, nil
}

func rawEvent(e entry) string {
	props := `{}`
	if e.jsonText != "MISSING" {
		props = `{"amount":` + e.jsonText + `}`
	}
	// lago-api wire shape (kafka_producer_service.rb build_payload); http_ruby skips expressions.
	return fmt.Sprintf(`{"organization_id":%q,"external_subscription_id":%q,"transaction_id":"vc-%s","code":"api_calls",`+
		`"properties":%s,"timestamp":"1741007009.123","precise_total_amount_cents":"0.0","source":"http_ruby",`+
		`"source_metadata":{"api_post_processed":false},"ingested_at":%q}`,
		fixture.Org, fixture.SubExternal, e.id, props, fixture.IngestedNow())
}

// exactDecimal parses s as an exact decimal (sign, digits, fraction, exponent).
// ok=false means ClickHouse's ...OrZero would yield 0.
func exactDecimal(s string) (*big.Rat, bool) {
	if s == "" || strings.ContainsAny(s, " /_xXpP") || strings.EqualFold(s, "inf") || strings.EqualFold(s, "nan") {
		return new(big.Rat), false
	}
	r, ok := new(big.Rat).SetString(s)
	if !ok {
		return new(big.Rat), false
	}
	return r, true
}

var chLimit = new(big.Rat).SetInt64(1_000_000_000_000) // Decimal(38,26): 38-26 = 12 integer digits

func chDecimal(goDec *big.Rat) *big.Rat {
	if new(big.Rat).Abs(goDec).Cmp(chLimit) >= 0 {
		return new(big.Rat)
	}
	return goDec
}

func fmtRat(r *big.Rat) string {
	if r.IsInt() {
		return r.Num().String()
	}
	s := r.FloatString(30)
	s = strings.TrimRight(s, "0")
	return strings.TrimSuffix(s, ".")
}

func ratEq(a *big.Rat, s string) bool {
	b, ok := new(big.Rat).SetString(s)
	return ok && a.Cmp(b) == 0
}

func runValue(useRuby bool, chBin string) (rows, valueMis, goDecMis, chZero, e2e int, err error) {
	corpus, err := parseCorpus()
	if err != nil {
		return
	}
	c, err := cache.NewCache(cache.CacheConfig{})
	if err != nil {
		return
	}
	defer c.Close()
	if err = fixture.SeedCache(c); err != nil {
		return
	}
	enrich := events_processor.NewEventEnrichmentService(nil, c)

	rubyWant := map[string][2]string{}
	if useRuby {
		if rubyWant, err = rubyDerive(corpus); err != nil {
			return
		}
	}

	type res struct {
		e                entry
		goValue          string
		goDec, chDec     *big.Rat
		valueOK, goDecOK bool
		chOK             bool
		verdict          string
	}
	var results []res
	goValues := []string{}
	for _, e := range corpus {
		var ev models.Event
		r := res{e: e}
		if uerr := json.Unmarshal([]byte(rawEvent(e)), &ev); uerr != nil {
			r.goValue = "ERR(unmarshal)"
		} else {
			er := enrich.EnrichEvent(&ev)
			switch {
			case er.Failure():
				r.goValue = "ERR(" + er.ErrorCode() + ")"
			case er.Value().Value == nil:
				r.goValue = "ERR(nil value)"
			default:
				r.goValue = *er.Value().Value
			}
		}
		goValues = append(goValues, r.goValue)
		r.goDec, _ = exactDecimal(r.goValue)
		r.chDec = chDecimal(r.goDec)
		r.valueOK = e.wantValue == "n/a" || r.goValue == e.wantValue
		r.goDecOK = ratEq(r.goDec, e.wantDecimal)
		r.chOK = ratEq(r.chDec, e.wantDecimal)
		var tags []string
		if !r.valueOK {
			switch {
			case r.goValue == "<nil>":
				tags = append(tags, "NIL")
			case r.goDecOK:
				tags = append(tags, "FORMAT")
			}
		}
		if !r.goDecOK {
			tags = append(tags, "PRECISION")
		}
		if r.goDecOK && !r.chOK {
			tags = append(tags, "CH_ZERO")
		} else if !r.goDecOK && r.chDec.Sign() == 0 && !ratEq(new(big.Rat), e.wantDecimal) {
			tags = append(tags, "CH_ZERO")
		}
		if len(tags) == 0 {
			tags = []string{"OK"}
		}
		r.verdict = strings.Join(tags, "+")
		results = append(results, r)
	}

	fmt.Println("== value corpus (BM api_calls: sum of properties.amount; real json.Unmarshal + EnrichEvent)")
	fmt.Printf("%-18s %-22s %-24s %-24s %-24s %-24s %s\n", "id", "json", "go_value", "want_value", "ch_decimal(emul)", "want_decimal", "verdict")
	for _, r := range results {
		rows++
		if !r.valueOK {
			valueMis++
		}
		if !r.goDecOK {
			goDecMis++
		}
		if r.goDecOK && !r.chOK {
			chZero++
		}
		if !r.chOK {
			e2e++
		}
		fmt.Printf("%-18s %-22s %-24s %-24s %-24s %-24s %s\n", r.e.id, trunc(r.e.jsonText, 22), trunc(r.goValue, 24),
			trunc(r.e.wantValue, 24), trunc(fmtRat(r.chDec), 24), trunc(r.e.wantDecimal, 24), r.verdict)
	}
	// unique_count compares raw value strings in ClickHouse
	// ($API/app/services/events/stores/clickhouse/unique_count_query.rb:311).
	var a, b string
	for _, r := range results {
		switch r.e.id {
		case "int_1e6":
			a = r.goValue
		case "str_1000000":
			b = r.goValue
		}
	}
	fmt.Printf("unique_count pair: number 1000000 -> %q, string \"1000000\" -> %q, same unique: %v (want true)\n", a, b, a == b)

	if useRuby {
		bad := 0
		for _, e := range corpus {
			w := rubyWant[e.id]
			if w[0] != e.wantValue || !strings.EqualFold(w[1], e.wantDecimal) {
				bad++
				fmt.Printf("ruby: %s corpus.tsv says (%s, %s) but Ruby derives (%s, %s)\n", e.id, e.wantValue, e.wantDecimal, w[0], w[1])
			}
		}
		fmt.Printf("ruby cross-check of want columns: %d/%d rows agree\n", len(corpus)-bad, len(corpus))
		if bad > 0 {
			err = fmt.Errorf("corpus.tsv want columns disagree with Ruby on %d row(s)", bad)
			return
		}
	}
	if chBin != "" {
		if err = chCrossCheck(chBin, goValues); err != nil {
			return
		}
	}
	return
}

func rubyDerive(corpus []entry) (map[string][2]string, error) {
	var in strings.Builder
	for _, e := range corpus {
		b, _ := json.Marshal(map[string]string{"id": e.id, "event": rawEvent(e)})
		in.Write(b)
		in.WriteByte('\n')
	}
	cmd := exec.Command("ruby", "-e", railsRB)
	cmd.Stdin = strings.NewReader(in.String())
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("ruby: %w (is ruby installed?)", err)
	}
	m := map[string][2]string{}
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	for sc.Scan() {
		f := strings.Split(sc.Text(), "\t")
		if len(f) == 3 {
			m[f[0]] = [2]string{f[1], f[2]}
		}
	}
	return m, nil
}

// chCrossCheck runs every go_value through a real clickhouse binary and compares
// toDecimal128OrZero(v, 26) with the emulation.
func chCrossCheck(bin string, values []string) error {
	var q strings.Builder
	q.WriteString("SELECT v, toString(toDecimal128OrZero(v, 26)) FROM (SELECT arrayJoin([")
	for i, v := range values {
		if i > 0 {
			q.WriteString(",")
		}
		q.WriteString("'" + strings.ReplaceAll(v, "'", "\\'") + "'")
	}
	q.WriteString("]) AS v) FORMAT TSV")
	out, err := exec.Command(bin, "local", "--query", q.String()).Output()
	if err != nil {
		return fmt.Errorf("clickhouse local: %w", err)
	}
	ver, _ := exec.Command(bin, "local", "--query", "SELECT version()").Output()
	agree, total := 0, 0
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	for sc.Scan() {
		f := strings.Split(sc.Text(), "\t")
		if len(f) != 2 {
			continue
		}
		total++
		v := strings.ReplaceAll(f[0], "\\'", "'")
		gd, _ := exactDecimal(v)
		em := chDecimal(gd)
		if ratEq(em, f[1]) {
			agree++
		} else {
			fmt.Printf("ch cross-check: %q -> clickhouse %s, emulation %s\n", v, f[1], fmtRat(em))
		}
	}
	fmt.Printf("ch cross-check (toDecimal128OrZero(v, 26) on ClickHouse %s): %d/%d values agree with the emulation\n",
		strings.TrimSpace(string(ver)), agree, total)
	if agree != total {
		return errors.New("ClickHouse emulation disagrees with the real binary")
	}
	return nil
}

func runTime() (mis int, rfcOK bool) {
	const base = 1741007009
	var first []string
	for ms := 0; ms < 1000; ms++ {
		in := fmt.Sprintf("%d.%03d", base, ms)
		r := utils.ToTime(in)
		if r.Failure() || r.Value().Nanosecond()/int(time.Millisecond) != ms || r.Value().Unix() != base {
			mis++
			if len(first) < 3 {
				first = append(first, fmt.Sprintf("%s -> %s", in, r.Value().Format("15:04:05.000Z07:00")))
			}
		}
	}
	rfc := "2025-03-03T15:03:29.123456+02:00"
	t := utils.ToTime(rfc).Value()
	rfcOK = t.Location() == time.UTC && t.Nanosecond()%int(time.Millisecond) == 0
	fmt.Println("== time precision (utils.ToTime, events-processor/utils/time.go:14)")
	fmt.Printf("ToTime(\"%d.<ms>\") ms=0..999: %d/1000 land on a different millisecond; first: %s\n", base, mis, strings.Join(first, "; "))
	_, off := t.Zone()
	fmt.Printf("ToTime(%q) = %s (utc_offset_s=%d, sub-ms ns=%d) -> normalised to UTC+ms: %v\n",
		rfc, t.Format(time.RFC3339Nano), off, t.Nanosecond()%int(time.Millisecond), rfcOK)
	return
}

func trunc(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-3] + "..."
}

func main() {
	mode := flag.String("mode", "all", "all | value | time")
	useRuby := flag.Bool("ruby", false, "re-derive the want columns with Ruby (json + bigdecimal) and fail if corpus.tsv disagrees")
	chBin := flag.String("ch-bin", "", "path to a clickhouse binary: cross-check the Decimal(38,26) emulation")
	failOn := flag.Bool("fail-on-mismatch", false, "exit 1 when any mismatch is found")
	verbose := flag.Bool("v", false, "show events-processor logs")
	flag.Parse()
	if !*verbose {
		slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	}

	summary := []string{}
	anyMis := false
	if *mode == "all" || *mode == "value" {
		rows, vm, gm, cz, e2e, err := runValue(*useRuby, *chBin)
		if err != nil {
			fmt.Fprintln(os.Stderr, "value-corpus: setup error:", err)
			os.Exit(2)
		}
		summary = append(summary, fmt.Sprintf("corpus_rows=%d value_mismatches=%d go_decimal_mismatches=%d ch_zeroed=%d end_to_end_decimal_mismatches=%d", rows, vm, gm, cz, e2e))
		anyMis = anyMis || vm+gm+e2e > 0
		fmt.Println()
	}
	if *mode == "all" || *mode == "time" {
		mis, ok := runTime()
		summary = append(summary, fmt.Sprintf("totime_mismatches=%d/1000 rfc3339_utc_ms=%v", mis, ok))
		anyMis = anyMis || mis > 0 || !ok
	}
	if len(summary) == 0 {
		fmt.Fprintln(os.Stderr, "value-corpus: -mode must be all, value or time")
		os.Exit(2)
	}
	fmt.Println("SUMMARY " + strings.Join(summary, " "))
	if *failOn && anyMis {
		os.Exit(1)
	}
}
