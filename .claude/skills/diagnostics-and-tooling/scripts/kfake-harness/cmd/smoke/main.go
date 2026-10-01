// smoke: run the BUILT events-processor binary end to end against kfake
// (listening on 127.0.0.1 TCP ports), miniredis and a Postgres database, feed
// it nine raw events (A..I), and report where each one landed.
//
// Question it answers: "what does the real binary, started exactly as in
// production (env vars, startup checks, graceful shutdown), do with each kind
// of event today?"
//
// Usage (no CGO needed for this driver; the binary itself needs
// LD_LIBRARY_PATH to find libexpression_go.so, which is passed through):
//
//	smoke -bin PATH -db-url URL [-mode db|cache|cache-cdc] [-log FILE] [-expected FILE] [-timeout 30s]
//
// The database must contain ../../fixtures/smoke-schema.sql (smoke-binary.sh
// does this with scratch-pg.sh). In cache modes the binary snapshots it at startup.
// cache-cdc additionally pre-produces one Debezium-unwrapped `charges` row for
// the pay-in-advance charge, shaped by extra/debezium_config.json
// column.include.list (which omits pay_in_advance). The real Debezium output
// was not observed here (no connector): that payload is hand-shaped.
//
// Exit codes: 0 ran (and matched -expected when given); 2 setup error;
// 3 observed dispositions differ from -expected (a measurement, read the diff).
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/alicebob/miniredis/v2"

	"lagoskills/kfakeharness/fixture"
	"lagoskills/kfakeharness/kfx"
)

const (
	raw       = "events-raw"
	enriched  = "events_enriched"
	inAdvance = "events_charged_in_advance"
	dlq       = "events_dead_letter"
	cdcPrefix = "lago_proc_cdc" // = extra/debezium_config.json topic.prefix
	group     = "smoke"         // real group id: smoke_events-raw
)

type tc struct{ id, what, payload string }

func cases() []tc {
	org, sub, now := fixture.Org, fixture.SubExternal, fixture.IngestedNow()
	ev := func(m map[string]any) string {
		m["organization_id"] = org
		m["ingested_at"] = now
		if _, ok := m["external_subscription_id"]; !ok {
			m["external_subscription_id"] = sub
		}
		return string(fixture.JSON(m))
	}
	return []tc{
		{"tx_A", "sum metric, active sub, pay-in-advance charge, property 0.0000001",
			ev(map[string]any{"transaction_id": "tx_A", "code": "api_calls", "properties": map[string]any{"amount": 0.0000001}, "timestamp": "1759320000.123", "source": "probe"})},
		{"tx_B", "unknown billable metric code",
			ev(map[string]any{"transaction_id": "tx_B", "code": "nope", "properties": map[string]any{}, "timestamp": "1759320000"})},
		{"tx_C", "unparsable timestamp \"2025-03-06 12:00:00\"",
			ev(map[string]any{"transaction_id": "tx_C", "code": "api_calls", "properties": map[string]any{}, "timestamp": "2025-03-06 12:00:00"})},
		{"tx_D", "invalid JSON payload", `{not json`},
		{"tx_E", "expression metric, extra boolean property",
			ev(map[string]any{"transaction_id": "tx_E", "code": "expr_metric", "properties": map[string]any{"a": 2, "flag": true}, "timestamp": 1759320000})},
		{"tx_F", "no matching subscription",
			ev(map[string]any{"transaction_id": "tx_F", "code": "count_calls", "external_subscription_id": "unknown_sub", "properties": map[string]any{}, "timestamp": 1759320000})},
		{"tx_G", "http_ruby source, api_post_processed=true",
			ev(map[string]any{"transaction_id": "tx_G", "code": "api_calls", "properties": map[string]any{"amount": 5}, "timestamp": "1759320000.5", "source": "http_ruby", "source_metadata": map[string]any{"api_post_processed": true}})},
		{"tx_H", "event at the ms the subscription started (started_at has +500us)",
			ev(map[string]any{"transaction_id": "tx_H", "code": "count_calls", "properties": map[string]any{}, "timestamp": "1735689600.000"})},
		{"tx_I", "expression metric OK",
			ev(map[string]any{"transaction_id": "tx_I", "code": "expr_metric", "properties": map[string]any{"a": 2}, "timestamp": 1759320000})},
	}
}

type disp struct {
	enriched, inAdvance bool
	value, sub, dlq     string
}

func main() {
	bin := flag.String("bin", "", "path to the built events-processor binary (required)")
	mode := flag.String("mode", "db", "db | cache | cache-cdc")
	dbURL := flag.String("db-url", "", "Postgres URL holding fixtures/smoke-schema.sql (required)")
	logPath := flag.String("log", "", "write the binary's stdout/stderr here (default: a temp file)")
	expected := flag.String("expected", "", "compare the observed result block with this file")
	timeout := flag.Duration("timeout", 30*time.Second, "max wait for the committed offset to reach the number of events")
	flag.Parse()
	if *bin == "" || *dbURL == "" {
		flag.Usage()
		os.Exit(2)
	}
	code, err := run(*bin, *mode, *dbURL, *logPath, *expected, *timeout)
	if err != nil {
		fmt.Fprintln(os.Stderr, "smoke: setup error:", err)
		os.Exit(2)
	}
	os.Exit(code)
}

func run(bin, mode, dbURL, logPath, expectedPath string, timeout time.Duration) (int, error) {
	ctx := context.Background()
	topics := []string{raw, enriched, inAdvance, dlq}
	for _, t := range []string{"billable_metrics", "subscriptions", "charges", "billable_metric_filters", "charge_filters", "charge_filter_values"} {
		topics = append(topics, cdcPrefix+".public."+t)
	}
	cl, err := kfx.Start(1, topics)
	if err != nil {
		return 0, err
	}
	defer cl.Close()
	mr, err := miniredis.Run()
	if err != nil {
		return 0, err
	}
	defer mr.Close()

	if mode == "cache-cdc" {
		upd := time.Now().Add(time.Minute).UnixMicro()
		row := fmt.Sprintf(`{"id":"%s","organization_id":"%s","plan_id":"%s","billable_metric_id":"%s","created_at":%d,"updated_at":%d,"deleted_at":null,"properties":"{}","__deleted":"false","__table":"charges","__lsn":1}`,
			fixture.ChargeSumInAdvance, fixture.Org, fixture.Plan, fixture.BMSum, upd, upd)
		if err := cl.Produce(ctx, cdcPrefix+".public.charges", []byte(row)); err != nil {
			return 0, err
		}
	}

	if logPath == "" {
		f, err := os.CreateTemp("", "ep-smoke-*.log")
		if err != nil {
			return 0, err
		}
		logPath = f.Name()
		f.Close()
	}
	lf, err := os.Create(logPath)
	if err != nil {
		return 0, err
	}
	defer lf.Close()

	env := []string{
		"PATH=" + os.Getenv("PATH"),
		"LD_LIBRARY_PATH=" + os.Getenv("LD_LIBRARY_PATH"),
		"ENV=development",
		"LAGO_KAFKA_BOOTSTRAP_SERVERS=" + cl.Addrs[0],
		"LAGO_KAFKA_RAW_EVENTS_TOPIC=" + raw,
		"LAGO_KAFKA_ENRICHED_EVENTS_TOPIC=" + enriched,
		"LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC=" + inAdvance,
		"LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC=" + dlq,
		"LAGO_KAFKA_CONSUMER_GROUP=" + group,
		"LAGO_REDIS_STORE_URL=" + mr.Addr(),
		"DATABASE_URL=" + dbURL,
	}
	if mode == "cache" || mode == "cache-cdc" {
		env = append(env, "LAGO_USE_MEMORY_CACHE=true", "LAGO_DEBEZIUM_TOPIC_PREFIX="+cdcPrefix)
	} else if mode != "db" {
		return 0, fmt.Errorf("unknown -mode %q", mode)
	}
	cmd := exec.Command(bin)
	cmd.Env = env
	cmd.Stdout, cmd.Stderr = lf, lf
	started := time.Now()
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()

	cs := cases()
	vals := make([][]byte, 0, len(cs))
	for _, c := range cs {
		vals = append(vals, []byte(c.payload))
	}
	if err := cl.Produce(ctx, raw, vals...); err != nil {
		_ = cmd.Process.Kill()
		return 0, err
	}
	gid := group + "_" + raw
	committed, werr := cl.WaitCommitted(ctx, gid, raw, 0, int64(len(cs)), timeout)
	if werr != nil {
		fmt.Println("WARN", werr)
	}

	d := map[string]*disp{}
	get := func(tx string) *disp {
		if d[tx] == nil {
			d[tx] = &disp{}
		}
		return d[tx]
	}
	read := func(topic string, fn func([]byte)) {
		rs, err := cl.ReadAll(ctx, topic, 10*time.Second)
		if err != nil {
			fmt.Println("WARN", err)
		}
		for _, r := range rs {
			fn(r.Value)
		}
	}
	read(enriched, func(b []byte) {
		var e struct {
			Tx    string  `json:"transaction_id"`
			Value *string `json:"value"`
			Sub   string  `json:"subscription_id"`
		}
		_ = json.Unmarshal(b, &e)
		x := get(e.Tx)
		x.enriched = true
		x.value = "null"
		if e.Value != nil {
			x.value = fmt.Sprintf("%q", *e.Value)
		}
		x.sub = fmt.Sprintf("%q", e.Sub)
	})
	read(inAdvance, func(b []byte) {
		var e struct {
			Tx string `json:"transaction_id"`
		}
		_ = json.Unmarshal(b, &e)
		get(e.Tx).inAdvance = true
	})
	read(dlq, func(b []byte) {
		var e struct {
			Event struct {
				Tx string `json:"transaction_id"`
			} `json:"event"`
			Code    string `json:"error_code"`
			Initial string `json:"initial_error_message"`
		}
		_ = json.Unmarshal(b, &e)
		get(e.Event.Tx).dlq = fmt.Sprintf("%s(%s)", e.Code, e.Initial)
	})
	members, _ := mr.ZMembers("subscription_refreshed_v2")
	groups, _ := cl.Groups(ctx)
	sort.Strings(groups)

	_ = cmd.Process.Signal(syscall.SIGTERM)
	exitLine := ""
	select {
	case err := <-exited:
		exitLine = fmt.Sprintf("exit_after_sigterm=%v", err)
	case <-time.After(20 * time.Second):
		_ = cmd.Process.Kill()
		exitLine = "exit_after_sigterm=TIMEOUT(killed after 20s)"
	}
	uptime := time.Since(started).Round(100 * time.Millisecond)

	// Result block (compared with -expected). Only deterministic facts.
	var block []string
	accounted := 0
	for _, c := range cs {
		x := d[c.id]
		line := c.id + " "
		if x == nil {
			line += "on-no-output-topic"
		} else {
			accounted++
			yn := func(b bool) string {
				if b {
					return "yes"
				}
				return "no"
			}
			line += "enriched=" + yn(x.enriched)
			if x.enriched {
				line += " value=" + x.value + " subscription_id=" + x.sub
			}
			line += " in_advance=" + yn(x.inAdvance)
			if x.dlq != "" {
				line += " dlq=" + x.dlq
			}
		}
		block = append(block, line)
	}
	block = append(block,
		fmt.Sprintf("raw_events=%d accounted=%d on_no_output_topic=%d", len(cs), accounted, len(cs)-accounted),
		fmt.Sprintf("committed_offset=%d", committed),
		fmt.Sprintf("zset_members=%d", len(members)),
		exitLine,
	)
	cdcGroups := 0
	for _, g := range groups {
		if strings.HasPrefix(g, "lago_evp_") {
			cdcGroups++
		}
	}
	block = append(block, fmt.Sprintf("consumer_groups: %s + %d lago_evp_<model>_<uuid>", gid, cdcGroups))

	fmt.Printf("== smoke mode=%s bin=%s uptime=%s log=%s\n", mode, bin, uptime, logPath)
	for _, c := range cs {
		fmt.Printf("   %s: %s\n", c.id, c.what)
	}
	fmt.Println("== result")
	for _, l := range block {
		fmt.Println(l)
	}
	fmt.Println("== log summary (level counts; see debugging-playbook for triage)")
	fmt.Println(logSummary(logPath))

	if expectedPath == "" {
		return 0, nil
	}
	exp, err := readExpected(expectedPath)
	if err != nil {
		return 0, err
	}
	if diff := diffLines(exp, block); diff != "" {
		fmt.Printf("== EXPECTED-TODAY: DIFFERS from %s (- expected, + observed)\n%s", expectedPath, diff)
		return 3, nil
	}
	fmt.Printf("== EXPECTED-TODAY: MATCH (%s)\n", expectedPath)
	return 0, nil
}

func logSummary(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return err.Error()
	}
	defer f.Close()
	levels := map[string]int{}
	panics := 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		var l struct {
			Level string `json:"level"`
		}
		if json.Unmarshal(sc.Bytes(), &l) == nil && l.Level != "" {
			levels[l.Level]++
		} else if strings.HasPrefix(sc.Text(), "panic:") {
			panics++
		}
	}
	keys := []string{}
	for k := range levels {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := []string{}
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", k, levels[k]))
	}
	return fmt.Sprintf("%s panic_lines=%d", strings.Join(parts, " "), panics)
}

func readExpected(path string) ([]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		l = strings.TrimRight(l, " \r")
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		out = append(out, l)
	}
	return out, nil
}

func diffLines(exp, got []string) string {
	var sb strings.Builder
	n := len(exp)
	if len(got) > n {
		n = len(got)
	}
	for i := 0; i < n; i++ {
		var e, g string
		if i < len(exp) {
			e = exp[i]
		}
		if i < len(got) {
			g = got[i]
		}
		if e != g {
			if e != "" {
				sb.WriteString("- " + e + "\n")
			}
			if g != "" {
				sb.WriteString("+ " + g + "\n")
			}
		}
	}
	return sb.String()
}
