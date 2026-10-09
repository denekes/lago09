// epconf — black-box conformance runner for an events-processor implementation
// (events-processor-spec conformance suite, kit v1). Written for the kit; it does not
// import or copy events-processor code.
//
// The implementation under test (IUT) is ANY process started with --impl-cmd and
// configured only through environment variables. The runner owns the three
// external systems the IUT talks to:
//
//	Kafka    kfake, in this process, listening on 127.0.0.1 TCP (real Kafka protocol)
//	Redis    miniredis, in this process, listening on 127.0.0.1 TCP (RESP protocol)
//	Postgres a scratch database created from the scenario's catalog fixture
//
// Per scenario it: seeds Postgres, starts Kafka + Redis, starts the IUT, waits until
// the IUT has joined the consumer group (readiness), executes the scenario steps
// (produce raw events, inject faults, restart, wait for quiescence), stops the IUT
// with SIGTERM, collects every observable output (records on the 3 output topics,
// committed offsets of the raw-topic consumer group, ZSET members, exit status),
// renders a canonical "golden" text and compares it with the expected file.
//
// Usage:
//
//	epconf -impl-cmd CMD -scenario FILE [-mode db|cache] [-golden FILE [-update]]
//	       [-assert FILE] [-loose-errors] [-impl-env K=V ...] [-pg-admin URL] [-keep DIR] [-v]
//
// Exit codes: 0 match (and every decided assertion passes); 3 golden differs or a
// decided assertion fails; 2 setup error. Failing assertions whose ruling is
// "proposed" are reported as UNRULED and never change the exit code.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
)

// Interface constants (the env contract every implementation must honour).
const (
	topicRaw      = "events-raw"
	topicEnriched = "events_enriched"
	topicAdvance  = "events_charged_in_advance"
	topicDLQ      = "events_dead_letter"
	groupPrefix   = "epconf"
	zsetName      = "subscription_refreshed_v2"
)

var outTopics = []string{topicEnriched, topicAdvance, topicDLQ}

// ---------------------------------------------------------------- scenario model

type Scenario struct {
	Name          string            `json:"name"`
	ID            string            `json:"id"`    // EPC-NN (metadata)
	Rules         []string          `json:"rules"` // spec rules the scenario pins (metadata)
	RBD           []string          `json:"rbd"`   // rebuild decisions it exercises (metadata)
	Description   string            `json:"description"`
	Catalog       []string          `json:"catalog"`         // SQL files (relative to the scenario file) loaded in order
	SQL           []string          `json:"sql"`             // extra inline SQL after the catalog files
	DBFaultTables []string          `json:"db_fault_tables"` // tables wrapped by a fault-injection view before the IUT starts
	Partitions    int32             `json:"partitions"`      // raw topic partitions (default 1)
	Env           map[string]string `json:"env"`             // scenario env overrides ("" = set empty; "$UNSET" = remove)
	Defaults      map[string]any    `json:"defaults"`        // merged into every JSON event unless the key is present
	Steps         []Step            `json:"steps"`
	SettleMs      int               `json:"settle_ms"`           // quiescence: unchanged for this long with everything committed (default 1000)
	WithheldMs    int               `json:"withheld_settle_ms"`  // quiescence: unchanged for this long with records uncommitted (default 3000)
	ExpectNoReady bool              `json:"expect_no_ready"`     // startup-contract scenarios: the IUT must exit before joining
	DBConnLimit   int               `json:"db_connection_limit"` // ALTER DATABASE ... CONNECTION LIMIT n (the IUT role is not a superuser)
	NoGolden      bool              `json:"no_golden"`           // outcome is timing-dependent: only assertions apply
	Modes         []string          `json:"modes"`               // catalog-access modes the scenario applies to (default: db and cache)
}

type Step struct {
	Produce     []RawEvent `json:"produce,omitempty"`
	Wait        string     `json:"wait,omitempty"` // "quiescent"
	DBFault     *DBFault   `json:"db_fault,omitempty"`
	WaitDBFired string     `json:"wait_db_fault_fired,omitempty"` // table name
	RedisError  *string    `json:"redis_error,omitempty"`         // "" clears
	KafkaReject *[]string  `json:"kafka_reject_produce,omitempty"`
	Restart     string     `json:"restart,omitempty"` // "TERM" | "KILL"
	SleepMs     int        `json:"sleep_ms,omitempty"`
	SQL         string     `json:"sql,omitempty"`
	Note        string     `json:"note,omitempty"`
	CDC         *CDCRow    `json:"cdc,omitempty"`
	WaitCDC     string     `json:"wait_cdc_applied,omitempty"` // table: wait until some group committed the CDC topic's end offset
}

// CDCRow is one Debezium-unwrapped change row produced to <prefix>.public.<table>
// (memory-cache mode only). "$NOW_US" in a value becomes the current time in microseconds.
type CDCRow struct {
	Table string         `json:"table"`
	Row   map[string]any `json:"row"`
}

type DBFault struct {
	Table string `json:"table"`
	Times int    `json:"times"`
}

type RawEvent struct {
	JSON      map[string]any `json:"json,omitempty"`
	Raw       *string        `json:"raw,omitempty"`
	Key       *string        `json:"key,omitempty"`
	Partition int32          `json:"partition,omitempty"`
	Label     string         `json:"label,omitempty"` // ledger label when the payload has no transaction_id
	NoDefault bool           `json:"no_defaults,omitempty"`
}

// ---------------------------------------------------------------- main

type opts struct {
	implCmd   string
	implEnv   []string
	scenario  string
	golden    string
	assertF   string
	update    bool
	dbAdmin   string
	keep      string
	verbose   bool
	timeout   time.Duration
	readyWait time.Duration
	loose     bool
	mode      string
	describe  bool
}

type envList []string

func (e *envList) String() string { return strings.Join(*e, " ") }
func (e *envList) Set(v string) error {
	if !strings.Contains(v, "=") {
		return fmt.Errorf("want K=V, got %q", v)
	}
	*e = append(*e, v)
	return nil
}

func main() {
	var o opts
	var ie envList
	flag.StringVar(&o.implCmd, "impl-cmd", "", "command line of the implementation under test (run with sh -c)")
	flag.Var(&ie, "impl-env", "extra K=V for the IUT environment (repeatable)")
	flag.StringVar(&o.scenario, "scenario", "", "scenario JSON file")
	flag.StringVar(&o.golden, "golden", "", "expected golden file (compat profile)")
	flag.StringVar(&o.assertF, "assert", "", "assertion file (corrected profile)")
	flag.BoolVar(&o.update, "update", false, "write the observed golden to -golden instead of comparing")
	flag.StringVar(&o.dbAdmin, "pg-admin", envOr("EPCONF_PG_ADMIN_URL", "postgres://lago:lago@localhost:5432/lago"), "admin Postgres URL of the RUNNER (CREATE DATABASE / CREATE ROLE); never the IUT's DATABASE_URL")
	flag.StringVar(&o.keep, "keep", "", "directory to keep IUT logs and the observed golden in")
	flag.BoolVar(&o.verbose, "v", false, "verbose progress on stderr")
	flag.DurationVar(&o.timeout, "timeout", 60*time.Second, "max wait for any quiescence / readiness step")
	flag.DurationVar(&o.readyWait, "ready-timeout", 60*time.Second, "max wait for the IUT to join the consumer group")
	flag.BoolVar(&o.loose, "loose-errors", false, "compare initial_error_message only as present/absent (portable profile)")
	flag.StringVar(&o.mode, "mode", "db", "catalog access mode of the IUT: db (per-event Postgres) | cache (snapshot + CDC topics)")
	flag.BoolVar(&o.describe, "describe", false, "print 'applies=<bool> no_golden=<bool>' for -scenario and -mode, then exit (no IUT needed)")
	flag.Parse()
	o.implEnv = ie
	if o.mode != "db" && o.mode != "cache" {
		fmt.Fprintln(os.Stderr, "epconf: -mode must be db or cache")
		os.Exit(2)
	}
	if o.describe && o.scenario != "" {
		sc, err := loadScenario(o.scenario)
		if err != nil {
			fmt.Fprintln(os.Stderr, "epconf: setup error:", err)
			os.Exit(2)
		}
		applies := len(sc.Modes) == 0
		for _, m := range sc.Modes {
			applies = applies || m == o.mode
		}
		fmt.Printf("applies=%v no_golden=%v\n", applies, sc.NoGolden)
		os.Exit(0)
	}
	if o.implCmd == "" || o.scenario == "" {
		flag.Usage()
		os.Exit(2)
	}
	code, err := run(o)
	if err != nil {
		fmt.Fprintln(os.Stderr, "epconf: setup error:", err)
		os.Exit(2)
	}
	os.Exit(code)
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func logf(o opts, f string, a ...any) {
	if o.verbose {
		fmt.Fprintf(os.Stderr, "epconf: "+f+"\n", a...)
	}
}

// ---------------------------------------------------------------- run

type produced struct {
	label     string
	partition int32
	offset    int64
	value     string
}

type env struct {
	o        opts
	sc       *Scenario
	dir      string
	cl       *kfake.Cluster
	addrs    []string
	mr       *miniredis.Miniredis
	dbURL    string
	dbName   string
	iut      *iut
	starts   int
	raws     []produced
	reject   map[string]bool
	topicIDs map[[16]byte]string
	runStart time.Time
	notes    []string
	iutDBURL string
}

func run(o opts) (int, error) {
	sc, err := loadScenario(o.scenario)
	if err != nil {
		return 0, err
	}
	e := &env{o: o, sc: sc, dir: filepath.Dir(o.scenario), reject: map[string]bool{}, runStart: time.Now()}
	ctx := context.Background()
	if len(sc.Modes) > 0 {
		in := false
		for _, m := range sc.Modes {
			in = in || m == o.mode
		}
		if !in {
			fmt.Printf("== SKIPPED scenario %s does not apply to mode %s\n", sc.Name, o.mode)
			return 0, nil
		}
	}

	// 1. Postgres
	e.dbName = fmt.Sprintf("epconf_%d", os.Getpid())
	if e.dbURL, err = createDB(o.dbAdmin, e.dbName); err != nil {
		return 0, err
	}
	defer dropDB(o.dbAdmin, e.dbName)
	for _, f := range sc.Catalog {
		if err := psqlFile(e.dbURL, filepath.Join(e.dir, f)); err != nil {
			return 0, err
		}
	}
	for _, s := range sc.SQL {
		if err := psqlExec(e.dbURL, s); err != nil {
			return 0, err
		}
	}
	for _, t := range sc.DBFaultTables {
		if err := installDBFault(e.dbURL, t); err != nil {
			return 0, err
		}
	}
	// The IUT connects as a least-privilege role (SELECT only), so per-database
	// connection limits apply to it (they never apply to superusers).
	if err := grantIUT(o.dbAdmin, e.dbURL, e.dbName, sc.DBConnLimit); err != nil {
		return 0, err
	}
	e.iutDBURL = withUser(e.dbURL, "epconf_iut:epconf")

	// 2. Kafka + Redis
	parts := sc.Partitions
	if parts <= 0 {
		parts = 1
	}
	kopts := []kfake.Opt{kfake.NumBrokers(1), kfake.SeedTopics(parts, topicRaw), kfake.SeedTopics(1, outTopics...)}
	if o.mode == "cache" {
		kopts = append(kopts, kfake.SeedTopics(1, cdcTopics()...))
	}
	e.cl, err = kfake.NewCluster(kopts...)
	if err != nil {
		return 0, err
	}
	defer e.cl.Close()
	e.addrs = e.cl.ListenAddrs()
	e.installProduceControl()
	if err := e.loadTopicIDs(ctx); err != nil {
		return 0, err
	}
	e.mr, err = miniredis.Run()
	if err != nil {
		return 0, err
	}
	defer e.mr.Close()

	// 3. IUT
	if err := e.startIUT(); err != nil {
		return 0, err
	}
	ready := e.waitReady(ctx)
	if !ready && !sc.ExpectNoReady {
		e.notes = append(e.notes, "iut_not_ready")
	}

	// 4. steps
	if ready {
		for i, st := range sc.Steps {
			logf(o, "step %d", i)
			if err := e.step(ctx, st); err != nil {
				e.notes = append(e.notes, fmt.Sprintf("step %d: %v", i, err))
				break
			}
		}
	}

	// 5. stop + collect
	exitLine := e.stopIUT(ready)
	obs, err := e.collect(ctx)
	if err != nil {
		return 0, err
	}
	obs.exitLine = exitLine
	text := e.render(obs)

	if o.keep != "" {
		_ = os.MkdirAll(o.keep, 0o755)
		_ = os.WriteFile(filepath.Join(o.keep, sc.Name+".observed"), []byte(text), 0o644)
	}
	fmt.Print(text)

	rc := 0
	if o.golden != "" {
		if o.update {
			if err := os.WriteFile(o.golden, []byte(text), 0o644); err != nil {
				return 0, err
			}
			fmt.Printf("== GOLDEN WRITTEN %s\n", o.golden)
		} else {
			want, err := os.ReadFile(o.golden)
			if err != nil {
				return 0, err
			}
			w, g := string(want), text
			if o.loose {
				w, g = loosen(w), loosen(g)
			}
			if d := diffText(w, g); d != "" {
				fmt.Printf("== GOLDEN DIFFERS %s (- expected, + observed)\n%s", o.golden, d)
				rc = 3
			} else {
				fmt.Printf("== GOLDEN MATCH %s\n", o.golden)
			}
		}
	}
	if o.assertF != "" {
		fails, unruled, err := e.checkAssertions(o.assertF, obs)
		if err != nil {
			return 0, err
		}
		for _, f := range unruled {
			fmt.Println("  UNRULED-FAIL", f)
		}
		switch {
		case len(fails) > 0:
			fmt.Printf("== ASSERTIONS FAILED %s (%d decided, %d unruled)\n", o.assertF, len(fails), len(unruled))
			for _, f := range fails {
				fmt.Println("  FAIL", f)
			}
			rc = 3
		case len(unruled) > 0:
			fmt.Printf("== ASSERTIONS UNRULED %s (0 decided failures, %d unruled)\n", o.assertF, len(unruled))
		default:
			fmt.Printf("== ASSERTIONS PASS %s\n", o.assertF)
		}
	}
	return rc, nil
}

func loadScenario(path string) (*Scenario, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber() // keep number literals verbatim (1e21 stays 1e21 on the wire)
	d.DisallowUnknownFields()
	var sc Scenario
	if err := d.Decode(&sc); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if sc.Name == "" {
		sc.Name = strings.TrimSuffix(filepath.Base(path), ".json")
	}
	return &sc, nil
}

// ---------------------------------------------------------------- Postgres helpers

func createDB(admin, name string) (string, error) {
	if err := psqlExec(admin, fmt.Sprintf(`DROP DATABASE IF EXISTS "%s" WITH (FORCE)`, name)); err != nil {
		return "", err
	}
	if err := psqlExec(admin, fmt.Sprintf(`CREATE DATABASE "%s"`, name)); err != nil {
		return "", err
	}
	_ = psqlExec(admin, fmt.Sprintf(`COMMENT ON DATABASE "%s" IS 'lago-skills scratch'`, name))
	i := strings.LastIndex(admin, "/")
	q := ""
	base := admin
	if j := strings.Index(admin, "?"); j >= 0 {
		q = admin[j:]
		base = admin[:j]
		i = strings.LastIndex(base, "/")
	}
	return base[:i+1] + name + q, nil
}

func dropDB(admin, name string) {
	_ = psqlExec(admin, fmt.Sprintf(`DROP DATABASE IF EXISTS "%s" WITH (FORCE)`, name))
}

func psqlExec(url, sql string) error {
	out, err := exec.Command("psql", url, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-At", "-c", sql).CombinedOutput()
	if err != nil {
		return fmt.Errorf("psql: %v: %s (sql: %.120s)", err, strings.TrimSpace(string(out)), sql)
	}
	return nil
}

func psqlQuery(url, sql string) (string, error) {
	out, err := exec.Command("psql", url, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-At", "-c", sql).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("psql: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

func psqlFile(url, path string) error {
	out, err := exec.Command("psql", url, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", path).CombinedOutput()
	if err != nil {
		return fmt.Errorf("psql -f %s: %v: %s", path, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// installDBFault replaces table t by a view over the renamed table. The view's WHERE
// clause calls epconf_gate(t) once per query (uncorrelated scalar subquery = InitPlan);
// the gate draws a number from a non-transactional sequence and raises an error when
// the number falls in the armed window. Works for ANY client that queries t by name.
func installDBFault(url, t string) error {
	sql := `
CREATE TABLE IF NOT EXISTS epconf_fault (tbl text PRIMARY KEY, fail_from bigint NOT NULL DEFAULT 0, fail_to bigint NOT NULL DEFAULT 0);
CREATE OR REPLACE FUNCTION epconf_gate(t text) RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $f$
DECLARE n bigint; f record;
BEGIN
  n := nextval(format('epconf_calls_%s', t));
  SELECT fail_from, fail_to INTO f FROM epconf_fault WHERE tbl = t;
  IF FOUND AND n >= f.fail_from AND n < f.fail_to THEN
    RAISE EXCEPTION 'epconf injected transient fault on %', t USING ERRCODE = '58030';
  END IF;
  RETURN true;
END $f$;
CREATE SEQUENCE epconf_calls___T__;
INSERT INTO epconf_fault (tbl) VALUES ('__T__');
ALTER TABLE __T__ RENAME TO epconf_real___T__;
CREATE VIEW __T__ AS SELECT r.* FROM epconf_real___T__ r WHERE (SELECT epconf_gate('__T__'));
`
	return psqlExec(url, strings.ReplaceAll(sql, "__T__", t))
}

func grantIUT(admin, url, db string, limit int) error {
	_ = psqlExec(admin, `DO $$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='epconf_iut') THEN CREATE ROLE epconf_iut LOGIN PASSWORD 'epconf'; END IF; END$$`)
	if err := psqlExec(url, `GRANT SELECT ON ALL TABLES IN SCHEMA public TO epconf_iut`); err != nil {
		return err
	}
	if limit > 0 {
		return psqlExec(admin, fmt.Sprintf(`ALTER DATABASE "%s" CONNECTION LIMIT %d`, db, limit))
	}
	return nil
}

// withUser swaps the userinfo of a postgres:// URL.
func withUser(url, userinfo string) string {
	i := strings.Index(url, "://")
	j := strings.Index(url, "@")
	if i < 0 || j < 0 {
		return url
	}
	return url[:i+3] + userinfo + url[j:]
}

func armDBFault(url string, f DBFault) error {
	times := f.Times
	if times <= 0 {
		times = 1
	}
	cur, err := psqlQuery(url, fmt.Sprintf(`SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM epconf_calls_%s`, f.Table))
	if err != nil {
		return err
	}
	n, _ := strconv.ParseInt(cur, 10, 64)
	return psqlExec(url, fmt.Sprintf(`UPDATE epconf_fault SET fail_from=%d, fail_to=%d WHERE tbl='%s'`, n+1, n+1+int64(times), f.Table))
}

func dbFaultFired(url, t string) (bool, error) {
	out, err := psqlQuery(url, fmt.Sprintf(`SELECT (CASE WHEN s.is_called THEN s.last_value ELSE 0 END) >= f.fail_from AND f.fail_from > 0 FROM epconf_calls_%[1]s s, epconf_fault f WHERE f.tbl='%[1]s'`, t))
	if err != nil {
		return false, err
	}
	return out == "t", nil
}

// ---------------------------------------------------------------- Kafka helpers

func (e *env) client(extra ...kgo.Opt) (*kgo.Client, error) {
	return kgo.NewClient(append([]kgo.Opt{kgo.SeedBrokers(e.addrs...)}, extra...)...)
}

func (e *env) loadTopicIDs(ctx context.Context) error {
	c, err := e.client()
	if err != nil {
		return err
	}
	defer c.Close()
	td, err := kadm.NewClient(c).ListTopics(ctx)
	if err != nil {
		return err
	}
	e.topicIDs = map[[16]byte]string{}
	for _, t := range td {
		e.topicIDs[t.ID] = t.Topic
	}
	return nil
}

// installProduceControl answers INVALID_RECORD to produce requests for topics in e.reject.
func (e *env) installProduceControl() {
	e.cl.ControlKey(int16(kmsg.Produce), func(req kmsg.Request) (kmsg.Response, error, bool) {
		e.cl.KeepControl()
		pr := req.(*kmsg.ProduceRequest)
		name := func(t kmsg.ProduceRequestTopic) string {
			if t.Topic != "" {
				return t.Topic
			}
			return e.topicIDs[t.TopicID]
		}
		// Compatibility shim: kfake (pinned 2b5c574e9ddd) answers CORRUPT_MESSAGE unless a
		// produced batch carries PartitionLeaderEpoch = -1; librdkafka 2.15 sends 0. The
		// field (bytes 12..15 of the batch) is outside the CRC, so normalising it is safe.
		for _, t := range pr.Topics {
			for _, p := range t.Partitions {
				if len(p.Records) >= 16 {
					p.Records[12], p.Records[13], p.Records[14], p.Records[15] = 0xff, 0xff, 0xff, 0xff
				}
			}
		}
		hit := false
		for _, t := range pr.Topics {
			if e.reject[name(t)] {
				hit = true
			}
		}
		if !hit {
			return nil, nil, false
		}
		resp := pr.ResponseKind().(*kmsg.ProduceResponse)
		for _, t := range pr.Topics {
			rt := kmsg.NewProduceResponseTopic()
			rt.Topic, rt.TopicID = t.Topic, t.TopicID
			for _, p := range t.Partitions {
				rp := kmsg.NewProduceResponseTopicPartition()
				rp.Partition = p.Partition
				rp.ErrorCode = kerr.InvalidRecord.Code
				rt.Partitions = append(rt.Partitions, rp)
			}
			resp.Topics = append(resp.Topics, rt)
		}
		return resp, nil, true
	})
}

func (e *env) group() string { return groupPrefix + "_" + topicRaw }

const cdcPrefix = "epconf_cdc"

var cdcTables = []string{"billable_metrics", "subscriptions", "charges", "billable_metric_filters", "charge_filters", "charge_filter_values"}

func cdcTopics() []string {
	out := []string{}
	for _, t := range cdcTables {
		out = append(out, cdcPrefix+".public."+t)
	}
	return out
}

// waitCDC: black-box signal that a CDC row was applied = some consumer group (other
// than the raw-topic group) has committed the CDC topic up to its end offset.
func (e *env) waitCDC(ctx context.Context, topic string) error {
	deadline := time.Now().Add(e.o.timeout)
	for time.Now().Before(deadline) {
		ends, err := e.endOffsets(ctx, topic)
		if err != nil {
			return err
		}
		hw := ends[topic][0]
		c, err := e.client()
		if err != nil {
			return err
		}
		adm := kadm.NewClient(c)
		gs, err := adm.ListGroups(ctx)
		if err == nil {
			for _, g := range gs.Groups() {
				if g == e.group() {
					continue
				}
				resp, err := adm.FetchOffsets(ctx, g)
				if err != nil {
					continue
				}
				if o, ok := resp.Lookup(topic, 0); ok && o.Err == nil && o.At >= hw {
					c.Close()
					return nil
				}
			}
		}
		c.Close()
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("CDC topic %s not consumed to its end", topic)
}

func (e *env) produceCDC(ctx context.Context, c CDCRow) error {
	m := map[string]any{}
	now := time.Now()
	for k, v := range c.Row {
		if s, ok := v.(string); ok && s == "$NOW_US" {
			v = json.Number(strconv.FormatInt(now.UnixMicro(), 10))
		}
		m[k] = v
	}
	b, err := marshalCanon(m)
	if err != nil {
		return err
	}
	cl, err := e.client()
	if err != nil {
		return err
	}
	defer cl.Close()
	return cl.ProduceSync(ctx, &kgo.Record{Topic: cdcPrefix + ".public." + c.Table, Value: b}).FirstErr()
}

func (e *env) endOffsets(ctx context.Context, topics ...string) (map[string]map[int32]int64, error) {
	c, err := e.client()
	if err != nil {
		return nil, err
	}
	defer c.Close()
	ends, err := kadm.NewClient(c).ListEndOffsets(ctx, topics...)
	if err != nil {
		return nil, err
	}
	out := map[string]map[int32]int64{}
	ends.Each(func(o kadm.ListedOffset) {
		if out[o.Topic] == nil {
			out[o.Topic] = map[int32]int64{}
		}
		out[o.Topic][o.Partition] = o.Offset
	})
	return out, nil
}

func (e *env) committed(ctx context.Context) (map[int32]int64, error) {
	c, err := e.client()
	if err != nil {
		return nil, err
	}
	defer c.Close()
	resp, err := kadm.NewClient(c).FetchOffsets(ctx, e.group())
	out := map[int32]int64{}
	if errors.Is(err, kerr.GroupIDNotFound) {
		return out, nil // the IUT never joined: nothing committed
	}
	if err != nil {
		return nil, err
	}
	resp.Each(func(o kadm.OffsetResponse) {
		if o.Topic == topicRaw && o.Err == nil {
			out[o.Partition] = o.At
		}
	})
	return out, nil
}

func (e *env) readAll(ctx context.Context, topic string) ([]*kgo.Record, error) {
	ends, err := e.endOffsets(ctx, topic)
	if err != nil {
		return nil, err
	}
	want := map[int32]int64{}
	for p, o := range ends[topic] {
		if o > 0 {
			want[p] = o
		}
	}
	if len(want) == 0 {
		return nil, nil
	}
	c, err := e.client(kgo.ConsumeTopics(topic), kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	if err != nil {
		return nil, err
	}
	defer c.Close()
	tctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	var out []*kgo.Record
	for len(want) > 0 {
		fs := c.PollFetches(tctx)
		if tctx.Err() != nil {
			return out, fmt.Errorf("readAll %s: timeout", topic)
		}
		fs.EachRecord(func(r *kgo.Record) {
			out = append(out, r)
			if hw, ok := want[r.Partition]; ok && r.Offset+1 >= hw {
				delete(want, r.Partition)
			}
		})
	}
	return out, nil
}

// ---------------------------------------------------------------- IUT process

type iut struct {
	cmd    *exec.Cmd
	exited chan error
	log    *os.File
}

func (e *env) iutEnv() []string {
	base := []string{}
	for _, k := range []string{"PATH", "HOME", "LD_LIBRARY_PATH", "TMPDIR"} {
		if v, ok := os.LookupEnv(k); ok {
			base = append(base, k+"="+v)
		}
	}
	contract := map[string]string{
		"ENV":                                        "development",
		"LAGO_KAFKA_BOOTSTRAP_SERVERS":               strings.Join(e.addrs, ","),
		"LAGO_KAFKA_RAW_EVENTS_TOPIC":                topicRaw,
		"LAGO_KAFKA_ENRICHED_EVENTS_TOPIC":           topicEnriched,
		"LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC": topicAdvance,
		"LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC":        topicDLQ,
		"LAGO_KAFKA_CONSUMER_GROUP":                  groupPrefix,
		"LAGO_REDIS_STORE_URL":                       e.mr.Addr(),
		"LAGO_REDIS_STORE_DB":                        "0",
		"DATABASE_URL":                               e.iutDBURL,
	}
	if e.o.mode == "cache" {
		contract["LAGO_USE_MEMORY_CACHE"] = "true"
		contract["LAGO_DEBEZIUM_TOPIC_PREFIX"] = cdcPrefix
	}
	for k, v := range e.sc.Env {
		if v == "$UNSET" {
			delete(contract, k)
			continue
		}
		contract[k] = v
	}
	keys := make([]string, 0, len(contract))
	for k := range contract {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		base = append(base, k+"="+contract[k])
	}
	return append(base, e.o.implEnv...)
}

func (e *env) startIUT() error {
	e.starts++
	logPath := filepath.Join(os.TempDir(), fmt.Sprintf("epconf-%s-%d-%d.log", e.sc.Name, os.Getpid(), e.starts))
	if e.o.keep != "" {
		_ = os.MkdirAll(e.o.keep, 0o755)
		logPath = filepath.Join(e.o.keep, fmt.Sprintf("%s.iut-%d.log", e.sc.Name, e.starts))
	}
	lf, err := os.Create(logPath)
	if err != nil {
		return err
	}
	// exec: the IUT replaces the shell, so signals and the exit status are its own.
	cmd := exec.Command("sh", "-c", "exec "+e.o.implCmd)
	cmd.Env = e.iutEnv()
	cmd.Stdout, cmd.Stderr = lf, lf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	ch := make(chan error, 1)
	go func() { ch <- cmd.Wait() }()
	e.iut = &iut{cmd: cmd, exited: ch, log: lf}
	logf(e.o, "started IUT #%d pid %d log %s", e.starts, cmd.Process.Pid, logPath)
	return nil
}

// waitReady: the IUT is ready when the consumer group <prefix>_<raw topic> is Stable
// and its members own every raw partition. Returns false if the IUT exits first.
func (e *env) waitReady(ctx context.Context) bool {
	wait := e.o.readyWait
	if e.sc.ExpectNoReady && wait > 30*time.Second {
		wait = 30 * time.Second // startup-contract scenarios: the IUT must fail within 30 s
	}
	deadline := time.Now().Add(wait)
	parts := e.sc.Partitions
	if parts <= 0 {
		parts = 1
	}
	for time.Now().Before(deadline) {
		select {
		case err := <-e.iut.exited:
			e.iut.exited <- err // keep it for stopIUT
			return false
		default:
		}
		c, err := e.client()
		if err == nil {
			dg, err := kadm.NewClient(c).DescribeGroups(ctx, e.group())
			c.Close()
			if err == nil {
				if g, ok := dg[e.group()]; ok && g.State == "Stable" {
					owned := int32(0)
					for _, m := range g.Members {
						if ca, ok := m.Assigned.AsConsumer(); ok {
							for _, t := range ca.Topics {
								if t.Topic == topicRaw {
									owned += int32(len(t.Partitions))
								}
							}
						}
					}
					if owned >= parts {
						return true
					}
				}
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return false
}

func (e *env) signalIUT(sig syscall.Signal) {
	if e.iut != nil && e.iut.cmd.Process != nil {
		_ = syscall.Kill(-e.iut.cmd.Process.Pid, sig)
	}
}

// stopIUT sends SIGTERM (unless the IUT already exited) and reports the exit status.
func (e *env) stopIUT(wasReady bool) string {
	select {
	case err := <-e.iut.exited:
		e.iut.log.Close()
		if wasReady {
			return "exit_before_sigterm=" + exitStatus(err)
		}
		return "exit_before_ready=" + exitStatus(err)
	default:
	}
	e.signalIUT(syscall.SIGTERM)
	select {
	case err := <-e.iut.exited:
		e.iut.log.Close()
		return "exit_after_sigterm=" + exitStatus(err)
	case <-time.After(30 * time.Second):
		e.signalIUT(syscall.SIGKILL)
		<-e.iut.exited
		e.iut.log.Close()
		return "exit_after_sigterm=TIMEOUT(killed after 30s)"
	}
}

func exitStatus(err error) string {
	if err == nil {
		return "0"
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return "signal(" + ws.Signal().String() + ")"
		}
		return strconv.Itoa(ee.ExitCode())
	}
	return err.Error()
}

// ---------------------------------------------------------------- steps

func (e *env) step(ctx context.Context, st Step) error {
	switch {
	case len(st.Produce) > 0:
		return e.produce(ctx, st.Produce)
	case st.Wait == "quiescent":
		return e.waitQuiescent(ctx)
	case st.DBFault != nil:
		return armDBFault(e.dbURL, *st.DBFault)
	case st.WaitDBFired != "":
		deadline := time.Now().Add(e.o.timeout)
		for time.Now().Before(deadline) {
			ok, err := dbFaultFired(e.dbURL, st.WaitDBFired)
			if err != nil {
				return err
			}
			if ok {
				return nil
			}
			time.Sleep(50 * time.Millisecond)
		}
		return fmt.Errorf("db fault on %s never fired", st.WaitDBFired)
	case st.RedisError != nil:
		e.mr.SetError(*st.RedisError)
		return nil
	case st.KafkaReject != nil:
		e.reject = map[string]bool{}
		for _, t := range *st.KafkaReject {
			e.reject[t] = true
		}
		return nil
	case st.Restart != "":
		sig := syscall.SIGTERM
		if st.Restart == "KILL" {
			sig = syscall.SIGKILL
		}
		e.signalIUT(sig)
		select {
		case <-e.iut.exited:
		case <-time.After(30 * time.Second):
			e.signalIUT(syscall.SIGKILL)
			<-e.iut.exited
		}
		e.iut.log.Close()
		if err := e.startIUT(); err != nil {
			return err
		}
		if !e.waitReady(ctx) {
			return fmt.Errorf("IUT not ready after restart")
		}
		return nil
	case st.SleepMs > 0:
		time.Sleep(time.Duration(st.SleepMs) * time.Millisecond)
		return nil
	case st.SQL != "":
		return psqlExec(e.dbURL, st.SQL)
	case st.Note != "":
		return nil
	case st.CDC != nil:
		return e.produceCDC(ctx, *st.CDC)
	case st.WaitCDC != "":
		return e.waitCDC(ctx, cdcPrefix+".public."+st.WaitCDC)
	}
	return fmt.Errorf("empty or unknown step")
}

func (e *env) produce(ctx context.Context, evs []RawEvent) error {
	c, err := e.client(kgo.RecordPartitioner(kgo.ManualPartitioner()))
	if err != nil {
		return err
	}
	defer c.Close()
	now := time.Now().UTC()
	recs := make([]*kgo.Record, 0, len(evs))
	labels := make([]string, 0, len(evs))
	for i, ev := range evs {
		var val []byte
		label := ev.Label
		if ev.Raw != nil {
			val = []byte(*ev.Raw)
		} else {
			m := map[string]any{}
			if !ev.NoDefault {
				for k, v := range e.sc.Defaults {
					m[k] = v
				}
			}
			for k, v := range ev.JSON {
				m[k] = v
			}
			for k, v := range m {
				if s, ok := v.(string); ok {
					if s == "$ABSENT" {
						delete(m, k)
						continue
					}
					m[k] = template(s, now)
				}
			}
			if label == "" {
				if tx, ok := m["transaction_id"].(string); ok {
					label = tx
				}
			}
			val, err = marshalCanon(m)
			if err != nil {
				return err
			}
		}
		if label == "" {
			label = fmt.Sprintf("raw#%d", len(e.raws)+i)
		}
		r := &kgo.Record{Topic: topicRaw, Value: val, Partition: ev.Partition}
		if ev.Key != nil {
			r.Key = []byte(*ev.Key)
		}
		recs = append(recs, r)
		labels = append(labels, label)
	}
	res := c.ProduceSync(ctx, recs...)
	if err := res.FirstErr(); err != nil {
		return err
	}
	// ProduceSync results are NOT in input order across partitions: map by record identity,
	// then keep the scenario's order in the ledger.
	idx := map[*kgo.Record]int{}
	for i, r := range recs {
		idx[r] = i
	}
	out := make([]produced, len(recs))
	for _, r := range res {
		i := idx[r.Record]
		out[i] = produced{label: labels[i], partition: r.Record.Partition, offset: r.Record.Offset, value: string(r.Record.Value)}
	}
	e.raws = append(e.raws, out...)
	return nil
}

func template(s string, now time.Time) string {
	switch s {
	case "$INGESTED_NOW":
		return now.Format("2006-01-02T15:04:05.000")
	case "$INGESTED_13H_AGO":
		return now.Add(-13 * time.Hour).Format("2006-01-02T15:04:05.000")
	case "$INGESTED_11H_AGO":
		return now.Add(-11 * time.Hour).Format("2006-01-02T15:04:05.000")
	case "$EPOCH_NOW":
		return strconv.FormatInt(now.Unix(), 10)
	}
	return s
}

type snapshot struct {
	ends      map[string]map[int32]int64
	committed map[int32]int64
	zcard     int
}

func (s snapshot) key() string {
	b, _ := json.Marshal([]any{s.ends, s.committed, s.zcard})
	return string(b)
}

func (s snapshot) allCommitted() bool {
	for p, hw := range s.ends[topicRaw] {
		c, ok := s.committed[p]
		if hw == 0 {
			continue
		}
		if !ok || c < hw {
			return false
		}
	}
	return true
}

// waitQuiescent: nothing observable changed for settle_ms with every raw record
// committed, or for withheld_settle_ms while some raw records stay uncommitted.
func (e *env) waitQuiescent(ctx context.Context) error {
	settle := time.Duration(e.sc.SettleMs) * time.Millisecond
	if settle <= 0 {
		settle = time.Second
	}
	withheld := time.Duration(e.sc.WithheldMs) * time.Millisecond
	if withheld <= 0 {
		withheld = 3 * time.Second
	}
	deadline := time.Now().Add(e.o.timeout)
	last := ""
	since := time.Now()
	for time.Now().Before(deadline) {
		select {
		case err := <-e.iut.exited:
			e.iut.exited <- err
			return fmt.Errorf("IUT exited during wait: %s", exitStatus(err))
		default:
		}
		ends, err := e.endOffsets(ctx, append([]string{topicRaw}, outTopics...)...)
		if err != nil {
			return err
		}
		com, err := e.committed(ctx)
		if err != nil {
			return err
		}
		zc := 0
		if ms, err := e.mr.ZMembers(zsetName); err == nil {
			zc = len(ms)
		}
		s := snapshot{ends, com, zc}
		k := s.key()
		if k != last {
			last, since = k, time.Now()
		}
		stable := time.Since(since)
		if s.allCommitted() && stable >= settle {
			return nil
		}
		if !s.allCommitted() && stable >= withheld {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("not quiescent after %s", e.o.timeout)
}

// ---------------------------------------------------------------- collect

type outRec struct {
	topic string
	key   string
	canon string
	obj   map[string]any
}

type observation struct {
	recs      map[string][]outRec
	committed map[int32]int64
	ends      map[int32]int64
	zmembers  []string
	zinvalid  []string
	groups    []string
	exitLine  string
}

func (e *env) collect(ctx context.Context) (*observation, error) {
	obs := &observation{recs: map[string][]outRec{}}
	for _, t := range outTopics {
		rs, err := e.readAll(ctx, t)
		if err != nil {
			return nil, err
		}
		for _, r := range rs {
			key := "<none>"
			if r.Key != nil {
				key = strconv.Quote(string(r.Key))
			}
			canon, obj := canonJSON(r.Value)
			obs.recs[t] = append(obs.recs[t], outRec{topic: t, key: key, canon: canon, obj: obj})
		}
	}
	var err error
	if obs.committed, err = e.committed(ctx); err != nil {
		return nil, err
	}
	ends, err := e.endOffsets(ctx, topicRaw)
	if err != nil {
		return nil, err
	}
	obs.ends = ends[topicRaw]
	members, _ := e.mr.ZMembers(zsetName)
	now := time.Now().Unix()
	re := regexp.MustCompile(`^(.*)\|(\d+)$`)
	seen := map[string]bool{}
	for _, m := range members {
		score, _ := e.mr.ZScore(zsetName, m)
		mm := re.FindStringSubmatch(m)
		if mm == nil {
			obs.zinvalid = append(obs.zinvalid, m)
			continue
		}
		b, _ := strconv.ParseInt(mm[2], 10, 64)
		sc := int64(score)
		okScore := sc >= e.runStart.Unix()-1 && sc <= now+1
		okBucket := b%10 == 0 && sc-b >= 0 && sc-b < 10
		if !okScore || !okBucket {
			obs.zinvalid = append(obs.zinvalid, fmt.Sprintf("%s score=%v", m, score))
			continue
		}
		masked := mm[1] + "|<BUCKET>"
		if !seen[masked] {
			seen[masked] = true
			obs.zmembers = append(obs.zmembers, masked)
		}
	}
	sort.Strings(obs.zmembers)
	if c, err := e.client(); err == nil {
		if gs, err := kadm.NewClient(c).ListGroups(ctx); err == nil {
			obs.groups = gs.Groups()
			sort.Strings(obs.groups)
		}
		c.Close()
	}
	return obs, nil
}

// canonJSON decodes with UseNumber (number literals kept verbatim), masks
// non-deterministic fields, and re-encodes with sorted keys and no HTML escaping.
func canonJSON(b []byte) (string, map[string]any) {
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return "NOT_JSON " + strconv.Quote(string(b)), nil
	}
	obj, _ := v.(map[string]any)
	if obj != nil {
		if fa, ok := obj["failed_at"].(string); ok {
			if _, err := time.Parse(time.RFC3339Nano, fa); err == nil {
				obj["failed_at"] = "<RFC3339>"
			} else {
				obj["failed_at"] = "<INVALID:" + fa + ">"
			}
		}
		if ev, ok := obj["event"].(map[string]any); ok {
			if ia, ok := ev["ingested_at"].(string); ok {
				ev["ingested_at"] = maskRecent(ia)
			}
		}
	}
	s, _ := marshalCanon(v)
	return string(s), obj
}

// maskRecent replaces a wall-clock string produced from a run-time template
// ($INGESTED_NOW / _11H_AGO / _13H_AGO) by "<NOW-Nh:layout>", keeping its SHAPE
// (the layout it was written in) as part of the contract. Fixed values pass through.
func maskRecent(s string) string {
	for _, layout := range []string{"2006-01-02T15:04:05", "2006-01-02T15:04:05.000"} {
		t, err := time.Parse(layout, s)
		if err != nil {
			continue
		}
		d := time.Since(t)
		for _, h := range []int{0, 11, 13} {
			off := d - time.Duration(h)*time.Hour
			if off > -2*time.Minute && off < 2*time.Minute {
				return fmt.Sprintf("<NOW-%dh:%s>", h, layout)
			}
		}
	}
	return s
}

func marshalCanon(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil { // map keys are sorted by encoding/json
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// ---------------------------------------------------------------- ledger + render

type ledgerRow struct {
	label     string
	partition int32
	offset    int64
	enriched  int
	advance   int
	dlq       int
	dlqCodes  []string
	committed bool
	class     string
}

func txOf(obj map[string]any, topic string) string {
	if obj == nil {
		return ""
	}
	if topic == topicDLQ {
		if ev, ok := obj["event"].(map[string]any); ok {
			if tx, ok := ev["transaction_id"].(string); ok {
				return tx
			}
		}
		return ""
	}
	tx, _ := obj["transaction_id"].(string)
	return tx
}

// attribute maps an output record to a raw-record label: by transaction_id, or, for a
// DLQ record that carries the original bytes in "raw_event" (corrected-profile DLQ shape
// for undecodable records), by byte equality with a produced raw value.
func (e *env) attribute(r outRec) string {
	if r.topic == topicDLQ && r.obj != nil {
		if raw, ok := r.obj["raw_event"].(string); ok {
			for _, p := range e.raws {
				if p.value == raw {
					return p.label
				}
			}
		}
	}
	return txOf(r.obj, r.topic)
}

func (e *env) ledger(obs *observation) []ledgerRow {
	count := map[string]map[string]int{}
	codes := map[string][]string{}
	for _, t := range outTopics {
		for _, r := range obs.recs[t] {
			tx := e.attribute(r)
			if count[tx] == nil {
				count[tx] = map[string]int{}
			}
			count[tx][t]++
			if t == topicDLQ {
				c, _ := r.obj["error_code"].(string)
				codes[tx] = append(codes[tx], fmt.Sprintf("%q", c))
			}
		}
	}
	rows := []ledgerRow{}
	for _, p := range e.raws {
		r := ledgerRow{label: p.label, partition: p.partition, offset: p.offset}
		c := count[p.label]
		if c != nil {
			r.enriched, r.advance, r.dlq = c[topicEnriched], c[topicAdvance], c[topicDLQ]
			r.dlqCodes = codes[p.label]
		}
		if co, ok := obs.committed[p.partition]; ok && p.offset < co {
			r.committed = true
		}
		switch {
		case r.enriched > 0 && r.dlq > 0:
			r.class = "ENRICHED+DLQ"
		case r.enriched > 0:
			r.class = "ENRICHED"
		case r.dlq > 0:
			r.class = "DLQ"
		case r.committed:
			r.class = "NO_OUTPUT_COMMITTED"
		default:
			r.class = "PENDING_UNCOMMITTED"
		}
		rows = append(rows, r)
	}
	return rows
}

func (e *env) render(obs *observation) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# epconf golden v1 scenario=%s mode=%s\n", e.sc.Name, e.o.mode)
	fmt.Fprintf(&b, "[ledger] label partition:offset class enriched/in_advance/dlq committed\n")
	for _, r := range e.ledger(obs) {
		fmt.Fprintf(&b, "%s p%d:o%d %s e=%d a=%d d=%d", r.label, r.partition, r.offset, r.class, r.enriched, r.advance, r.dlq)
		if len(r.dlqCodes) > 0 {
			fmt.Fprintf(&b, " codes=%s", strings.Join(r.dlqCodes, ","))
		}
		fmt.Fprintf(&b, " committed=%v\n", r.committed)
	}
	labels := map[string]bool{}
	for _, p := range e.raws {
		labels[p.label] = true
	}
	un := []string{}
	for _, t := range outTopics {
		for _, r := range obs.recs[t] {
			if tx := e.attribute(r); !labels[tx] {
				un = append(un, fmt.Sprintf("%s tx=%q", t, tx))
			}
		}
	}
	sort.Strings(un)
	fmt.Fprintf(&b, "[unattributed outputs] %d\n", len(un))
	for _, u := range un {
		fmt.Fprintf(&b, "%s\n", u)
	}
	for _, t := range outTopics {
		rs := append([]outRec(nil), obs.recs[t]...)
		sort.Slice(rs, func(i, j int) bool {
			if rs[i].key != rs[j].key {
				return rs[i].key < rs[j].key
			}
			return rs[i].canon < rs[j].canon
		})
		fmt.Fprintf(&b, "[topic %s] %d record(s)\n", t, len(rs))
		for _, r := range rs {
			fmt.Fprintf(&b, "key=%s %s\n", r.key, r.canon)
		}
	}
	fmt.Fprintf(&b, "[commits] group=%s\n", e.group())
	ps := []int{}
	for p := range obs.ends {
		ps = append(ps, int(p))
	}
	sort.Ints(ps)
	for _, p := range ps {
		c, ok := obs.committed[int32(p)]
		cs := "none"
		if ok {
			cs = strconv.FormatInt(c, 10)
		}
		fmt.Fprintf(&b, "p%d end=%d committed=%s\n", p, obs.ends[int32(p)], cs)
	}
	fmt.Fprintf(&b, "[redis %s] %d distinct masked member(s), %d invalid\n", zsetName, len(obs.zmembers), len(obs.zinvalid))
	for _, m := range obs.zmembers {
		fmt.Fprintf(&b, "%s\n", m)
	}
	for _, m := range obs.zinvalid {
		fmt.Fprintf(&b, "INVALID %s\n", m)
	}
	other := 0
	main := false
	for _, g := range obs.groups {
		if g == e.group() {
			main = true
		} else {
			other++
		}
	}
	og := strconv.Itoa(other)
	if strings.HasPrefix(obs.exitLine, "exit_before_ready") {
		og = "-" // groups created before a startup failure race with the exit: not compared
	}
	fmt.Fprintf(&b, "[process]\n%s\nstarts=%d\ngroup_present=%v other_groups=%s\n", obs.exitLine, e.starts, main, og)
	for _, n := range e.notes {
		fmt.Fprintf(&b, "NOTE %s\n", n)
	}
	return b.String()
}

// ---------------------------------------------------------------- assertions (corrected profile)

// Assertion is one corrected-profile check. Kinds: all_done, all_accounted, no_dup,
// value, on_dlq, done_with_cause, not_on_dlq, enriched, in_advance, not_in_advance,
// subscription, zset_has, zset_lacks, startup_exit.
type Assertion struct {
	Kind   string   `json:"kind"`
	Tx     string   `json:"tx,omitempty"`
	Want   string   `json:"want,omitempty"`
	AnyOf  []string `json:"any_of,omitempty"`
	Why    string   `json:"why"`
	RBD    []string `json:"rbd"`    // rebuild decisions the target depends on (reimplementation-kit RBD-n)
	Ruling string   `json:"ruling"` // decided | proposed (proposed = advisory, reported as UNRULED)
}

func (e *env) checkAssertions(path string, obs *observation) ([]string, []string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	var as []Assertion
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if err := d.Decode(&as); err != nil {
		return nil, nil, fmt.Errorf("%s: %w", path, err)
	}
	for i, a := range as {
		if len(a.RBD) == 0 || (a.Ruling != "decided" && a.Ruling != "proposed") {
			return nil, nil, fmt.Errorf("%s: assertion %d (%s) needs rbd and ruling decided|proposed", path, i, a.Kind)
		}
	}
	rows := e.ledger(obs)
	byTx := map[string][]map[string]any{}
	for _, r := range obs.recs[topicEnriched] {
		tx := txOf(r.obj, topicEnriched)
		byTx[tx] = append(byTx[tx], r.obj)
	}
	dlqBy := map[string][]map[string]any{}
	for _, r := range obs.recs[topicDLQ] {
		tx := e.attribute(r)
		dlqBy[tx] = append(dlqBy[tx], r.obj)
	}
	var fails, unruled []string
	fail := func(a Assertion, f string, x ...any) {
		line := fmt.Sprintf("%s %s: %s (%s; %s %s)", a.Kind, a.Tx, fmt.Sprintf(f, x...), a.Why, strings.Join(a.RBD, ","), a.Ruling)
		if a.Ruling == "proposed" {
			unruled = append(unruled, line)
		} else {
			fails = append(fails, line)
		}
	}
	// An IUT that never became ready (outside the startup-contract scenarios) produced
	// nothing, so ledger-wide kinds (all_done, all_accounted, no_dup) would pass vacuously.
	for _, n := range e.notes {
		if n == "iut_not_ready" {
			for _, a := range as {
				fail(a, "IUT never became ready (%s)", obs.exitLine)
			}
			return fails, unruled, nil
		}
	}
	for _, a := range as {
		switch a.Kind {
		case "all_accounted":
			for _, r := range rows {
				if r.class == "NO_OUTPUT_COMMITTED" {
					fail(a, "%s committed with no output (silent loss)", r.label)
				}
			}
		case "all_done":
			for _, r := range rows {
				if r.class != "ENRICHED" && r.class != "DLQ" {
					fail(a, "%s ended as %s", r.label, r.class)
				}
			}
		case "no_dup":
			for _, r := range rows {
				if r.enriched > 1 || r.advance > 1 {
					fail(a, "%s enriched=%d in_advance=%d", r.label, r.enriched, r.advance)
				}
			}
		case "value":
			got := byTx[a.Tx]
			if len(got) == 0 {
				fail(a, "not enriched")
				continue
			}
			v, _ := got[0]["value"].(string)
			ok := v == a.Want
			for _, w := range a.AnyOf {
				ok = ok || v == w
			}
			if !ok {
				fail(a, "value=%q want %q%v", v, a.Want, a.AnyOf)
			}
		case "on_dlq":
			got := dlqBy[a.Tx]
			if len(got) == 0 {
				fail(a, "not on DLQ")
				continue
			}
			c, _ := got[0]["error_code"].(string)
			if c == "" {
				fail(a, "on DLQ with an empty error_code")
			}
		case "done_with_cause": // enriched, or on the DLQ with a non-empty error_code
			if len(byTx[a.Tx]) > 0 {
				continue
			}
			ok := false
			for _, d := range dlqBy[a.Tx] {
				if c, _ := d["error_code"].(string); c != "" {
					ok = true
				}
			}
			if !ok {
				fail(a, "neither enriched nor on the DLQ with a cause")
			}
		case "not_on_dlq":
			if len(dlqBy[a.Tx]) > 0 {
				fail(a, "on DLQ")
			}
		case "enriched":
			if len(byTx[a.Tx]) == 0 {
				fail(a, "not enriched")
			}
		case "in_advance":
			n := 0
			for _, r := range obs.recs[topicAdvance] {
				if txOf(r.obj, topicAdvance) == a.Tx {
					n++
				}
			}
			if n == 0 {
				fail(a, "not on the charged-in-advance topic")
			}
		case "not_in_advance":
			for _, r := range obs.recs[topicAdvance] {
				if txOf(r.obj, topicAdvance) == a.Tx {
					fail(a, "on the charged-in-advance topic")
					break
				}
			}
		case "zset_has", "zset_lacks":
			has := false
			for _, m := range obs.zmembers {
				if strings.HasPrefix(m, a.Want+"|") {
					has = true
				}
			}
			if a.Kind == "zset_has" && !has {
				fail(a, "no refresh member %s", a.Want)
			}
			if a.Kind == "zset_lacks" && has {
				fail(a, "unexpected refresh member %s", a.Want)
			}
		case "startup_exit": // the IUT must exit non-zero before it joins the consumer group
			if !strings.HasPrefix(obs.exitLine, "exit_before_ready=") || obs.exitLine == "exit_before_ready=0" {
				fail(a, "process did not exit non-zero before readiness (%s)", obs.exitLine)
			}
		case "subscription":
			got := byTx[a.Tx]
			if len(got) == 0 {
				fail(a, "not enriched")
				continue
			}
			if s, _ := got[0]["subscription_id"].(string); s != a.Want {
				fail(a, "subscription_id=%q want %q", s, a.Want)
			}
		default:
			fail(a, "unknown assertion kind")
		}
	}
	return fails, unruled, nil
}

// ---------------------------------------------------------------- diff

var initialErrRe = regexp.MustCompile(`"initial_error_message":"(?:[^"\\]|\\.)*"`)

var exitBeforeReadyRe = regexp.MustCompile(`(?m)^exit_before_ready=([1-9][0-9]*|signal\([^)]*\))$`)

// loosen masks implementation-specific text: error messages (driver / parser
// messages) and the exact non-zero exit status of a startup failure.
func loosen(s string) string {
	s = initialErrRe.ReplaceAllStringFunc(s, func(m string) string {
		if m == `"initial_error_message":""` {
			return m
		}
		return `"initial_error_message":"<TEXT>"`
	})
	return exitBeforeReadyRe.ReplaceAllString(s, "exit_before_ready=NONZERO")
}

func diffText(want, got string) string {
	strip := func(s string) []string {
		var out []string
		sc := bufio.NewScanner(strings.NewReader(s))
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			l := strings.TrimRight(sc.Text(), " \r")
			if l == "" || strings.HasPrefix(l, "##") {
				continue
			}
			out = append(out, l)
		}
		return out
	}
	w, g := strip(want), strip(got)
	var sb strings.Builder
	gi := map[string]int{}
	for _, l := range g {
		gi[l]++
	}
	for _, l := range w {
		if gi[l] > 0 {
			gi[l]--
			continue
		}
		sb.WriteString("- " + l + "\n")
	}
	gi2 := map[string]int{}
	for _, l := range w {
		gi2[l]++
	}
	for _, l := range g {
		if gi2[l] > 0 {
			gi2[l]--
			continue
		}
		sb.WriteString("+ " + l + "\n")
	}
	return sb.String()
}
