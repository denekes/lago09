// accounting-probe: the event-accounting fault-matrix ledger.
//
// Question it answers: "for every raw-topic record, where did it END?"
// It drives the REAL events-processor consumer group (kafka.NewConsumerGroup:
// poll loop, processRecordsAndCommit, findMaxCommitableRecord) and the REAL
// processor (ProcessEvents -> EnrichEvent -> producers -> DLQ -> Redis flag)
// against in-process Kafka (kfake) and miniredis, in one of two data-source modes:
//   - db (default): models.ApiStore over a throwaway Postgres database (the dev default);
//   - cache: memory-cache mode, the mode production runs (LAGO_USE_MEMORY_CACHE=true,
//     DECIDED OD-1 (owner, 2026-10-02)): a fresh cache.Cache per case seeded with the
//     harness fixture (fixture.SeedCache); no Postgres, no Debezium CDC traffic.
//     Cases whose fault is injected at the Postgres edge (1-3) have no cache-mode
//     counterpart and are skipped.
//
// It injects one fault per case, restarts the consumer in the same group, and
// prints one ledger row per raw offset.
//
// Faults are injected only at the edges, never inside events-processor code:
//   - DB: a gorm Query callback fails the next N "subscriptions" queries
//     (transient DB error -> retryable fetch_subscription);
//   - Redis: miniredis.SetError while the fault record is in flight;
//   - Kafka produce: kfake answers Produce requests for chosen topics with
//     INVALID_RECORD (non-retriable), so kafka.Producer.Produce returns false;
//   - payloads: invalid JSON, numeric precise_total_amount_cents, unknown code,
//     ingested_at older than 12 h, a non-finite timestamp ("NaN");
//   - Postgres connection limit (opt-in case db-connection-exhaustion): a throwaway
//     non-superuser role with CONNECTION LIMIT 30 (superusers ignore the limit) and the
//     binary's default pool of 200 (processors/main_processor.go:134), with a burst
//     of 200 records in one poll.
//
// Opt-in cases (extraScenarios) run only when named with -case: they are kept out of
// the default run so the Phase-0 baseline (rows=36 / UNACCOUNTED=5, cache rows=26 /
// UNACCOUNTED=4) that scoreboard.sh and other skills quote does not move.
//
// Usage (CGO env required; use ../run.sh accounting-probe [flags]):
//
//	accounting-probe [-mode db|cache] [-case NAME[,NAME]] [-list] [-db-url URL] [-timeout 20s] [-v]
//
// Outcomes (one per raw offset):
//
//	ENRICHED       on events_enriched, decided "processed" on its only delivery
//	DLQ            on events_dead_letter (cause printed), not on events_enriched
//	REDELIVERED    delivered more than once, finally ENRICHED or DLQ (a bounded retry happened)
//	LOST           withheld for retry, then the committed offset moved past it; never redelivered; on no topic
//	SKIPPED_RETRY  withheld for retry, committed past, never redelivered, but partly produced before the failure
//	SENTRY_ONLY    decided "processed" (committed) but on no output topic: only logs/Sentry saw it
//	PENDING        withheld and not yet committed past (would be redelivered after a restart)
//	ENRICHED+DLQ   on both topics
//
// UNACCOUNTED = LOST + SKIPPED_RETRY + SENTRY_ONLY (violations of the campaign contract).
//
// Exit codes: 0 every record accounted; 1..99 = UNACCOUNTED rows (capped at 99);
// 100 setup error (Postgres unreachable in db mode, kfake/miniredis/cache start failure,
// bad flag, a -case without a counterpart in the chosen -mode, no CREATEROLE for
// db-connection-exhaustion).
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/getsentry/sentry-go"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
	"gorm.io/gorm"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/config/database"

	"lagoskills/kfakeharness/fixture"
	"lagoskills/kfakeharness/kfx"
	"lagoskills/kfakeharness/pipeline"
)

const (
	rawTopic      = "events-raw"
	enrichedTopic = "events_enriched"
	inAdvTopic    = "events_charged_in_advance"
	dlqTopic      = "events_dead_letter"
	groupPrefix   = "acct"
	zsetName      = "subscription_refreshed_v2"
)

type faultKind int

const (
	faultNone faultKind = iota
	faultDBSubscriptionOnce
	faultRedisOnce
	faultProduceEnriched
	faultProduceDLQ
	faultConnBurst // burstSize records in one poll against a role with CONNECTION LIMIT connLimit, pool 200
)

const (
	burstSize = 200 // records produced before the consumer starts: one poll, one batch
	connLimit = 30  // CONNECTION LIMIT of the throwaway role (the events-processor-spec EPC-30 shape)
	burstPool = 200 // LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS default (processors/main_processor.go:134)
)

type scenario struct {
	name     string
	what     string
	fault    faultKind
	payload  func(tx string) []byte
	later    bool   // produce 2 good records after the fault record's batch (production keeps flowing)
	expected string // today's fault-row outcome in db mode
	cacheExp string // today's fault-row outcome in cache mode; "" = no cache-mode counterpart (Postgres-edge fault)
}

// ---------- payloads (raw-topic wire format as lago-api sends it) ----------

func tsNow() string {
	t := time.Now().UTC()
	return fmt.Sprintf("%d.%03d", t.Unix(), t.Nanosecond()/int(time.Millisecond))
}

func good(tx string) []byte {
	return fixture.JSON(fixture.RawEvent{
		OrganizationID: fixture.Org, ExternalSubscriptionID: fixture.SubExternal, TransactionID: tx,
		Code: "api_calls", Properties: map[string]any{"amount": 5}, Timestamp: tsNow(),
		Source: "http_ruby", SourceMetadata: map[string]any{"api_post_processed": false},
		IngestedAt: fixture.IngestedNow(),
	})
}

func stale(tx string) []byte {
	return fixture.JSON(fixture.RawEvent{
		OrganizationID: fixture.Org, ExternalSubscriptionID: fixture.SubExternal, TransactionID: tx,
		Code: "api_calls", Properties: map[string]any{"amount": 5}, Timestamp: tsNow(),
		Source: "http_ruby", SourceMetadata: map[string]any{"api_post_processed": false},
		IngestedAt: time.Now().UTC().Add(-13 * time.Hour).Format("2006-01-02T15:04:05.000"),
	})
}

func unknownCode(tx string) []byte {
	return fixture.JSON(fixture.RawEvent{
		OrganizationID: fixture.Org, ExternalSubscriptionID: fixture.SubExternal, TransactionID: tx,
		Code: "no_such_metric", Properties: map[string]any{"amount": 5}, Timestamp: tsNow(),
		Source: "http_ruby", SourceMetadata: map[string]any{"api_post_processed": false},
		IngestedAt: fixture.IngestedNow(),
	})
}

func badJSON(tx string) []byte {
	return []byte(fmt.Sprintf(`{"organization_id":%q,"transaction_id":%q,"code":"api_calls","properties":{"amount":5`, fixture.Org, tx))
}

// numericPTAC is the connectors/*.yml shape: precise_total_amount_cents as a JSON number.
func numericPTAC(tx string) []byte {
	return fixture.JSON(map[string]any{
		"organization_id": fixture.Org, "external_subscription_id": fixture.SubExternal, "transaction_id": tx,
		"code": "api_calls", "properties": map[string]any{"amount": 5}, "timestamp": tsNow(),
		"precise_total_amount_cents": 100, "source": "http", "ingested_at": fixture.IngestedNow(),
	})
}

// nonFiniteTS sends timestamp "NaN": strconv.ParseFloat accepts it, so the event is
// enriched, but json.Marshal of the enriched record fails (utils/time.go:56-58,
// event_producer_service.go:77-79) and only a log line and a Sentry event remain.
func nonFiniteTS(tx string) []byte {
	return fixture.JSON(fixture.RawEvent{
		OrganizationID: fixture.Org, ExternalSubscriptionID: fixture.SubExternal, TransactionID: tx,
		Code: "api_calls", Properties: map[string]any{"amount": 5}, Timestamp: "NaN",
		Source: "http_ruby", SourceMetadata: map[string]any{"api_post_processed": false},
		IngestedAt: fixture.IngestedNow(),
	})
}

// extraScenarios run only when named with -case (see the header): they do not
// change the default TOTALS that scoreboard.sh baselines.
var extraScenarios = []scenario{
	{"db-connection-exhaustion", "burst of 200 records in one poll; Postgres role CONNECTION LIMIT 30 vs pool 200; 2 good records follow; restart (timing-dependent)",
		faultConnBurst, good, true, "burst: LOST > 0 (timing-dependent)", ""},
	{"non-finite-timestamp", "timestamp \"NaN\": enriched record cannot be marshalled",
		faultNone, nonFiniteTS, true, "fault=SENTRY_ONLY", "fault=SENTRY_ONLY"},
}

var scenarios = []scenario{
	{"retryable-then-later-batch", "transient DB error on the subscription lookup of a record alone in its batch; 2 good records follow; restart",
		faultDBSubscriptionOnce, good, true, "fault=LOST", ""},
	{"retryable-only-batch", "CONTROL: same transient DB error, nothing follows before the restart",
		faultDBSubscriptionOnce, good, false, "fault=REDELIVERED", ""},
	{"retryable-stale-12h", "same transient DB error on a record ingested 13 h ago",
		faultDBSubscriptionOnce, stale, true, "fault=DLQ(fetch_subscription)", ""},
	{"unmarshal-bad-json", "invalid JSON on the raw topic",
		faultNone, badJSON, true, "fault=SENTRY_ONLY", "fault=SENTRY_ONLY"},
	{"numeric-precise-total-amount-cents", "connector shape: precise_total_amount_cents as a JSON number",
		faultNone, numericPTAC, true, "fault=SENTRY_ONLY", "fault=SENTRY_ONLY"},
	{"enriched-produce-failure", "events_enriched rejects the fault record's produce (INVALID_RECORD)",
		faultProduceEnriched, good, true, "fault=DLQ(push events_enriched)", "fault=DLQ(push events_enriched)"},
	{"dlq-produce-failure", "unknown metric code (non-retryable) while events_dead_letter rejects produces",
		faultProduceDLQ, unknownCode, true, "fault=SENTRY_ONLY", "fault=SENTRY_ONLY"},
	{"redis-flag-then-later-batch", "Redis error on the refresh-flag ZADD of a record alone in its batch; 2 good records follow; restart",
		faultRedisOnce, good, true, "fault=SKIPPED_RETRY", "fault=SKIPPED_RETRY"},
	{"redis-flag-only-batch", "CONTROL: same Redis error, nothing follows before the restart",
		faultRedisOnce, good, false, "fault=REDELIVERED (enriched x2)", "fault=REDELIVERED (enriched x2)"},
	{"missing-bm-nonretryable", "unknown metric code: non-retryable fetch_billable_metric",
		faultNone, unknownCode, true, "fault=DLQ(fetch_billable_metric)", "fault=DLQ(fetch_billable_metric: Key not found)"},
}

// ---------- fault switches (edges only) ----------

var (
	burstDBURL     string       // connection-limited role URL (db-connection-exhaustion only)
	subQueryFaults atomic.Int32 // remaining subscription queries to fail
	failTopicsMu   sync.Mutex
	failTopics     = map[string]bool{}
	topicNames     = map[[16]byte]string{}
	sentryCount    atomic.Int64
)

func setFailTopics(ts ...string) {
	failTopicsMu.Lock()
	defer failTopicsMu.Unlock()
	failTopics = map[string]bool{}
	for _, t := range ts {
		failTopics[t] = true
	}
}

func registerDBFault(db *gorm.DB) error {
	return db.Callback().Query().Before("gorm:query").Register("acct:inject-subscription-fault", func(tx *gorm.DB) {
		if tx.Statement.Table != "subscriptions" {
			return
		}
		for {
			n := subQueryFaults.Load()
			if n <= 0 {
				return
			}
			if subQueryFaults.CompareAndSwap(n, n-1) {
				break
			}
		}
		_ = tx.AddError(errors.New("accounting-probe injected transient DB error: read: connection reset by peer"))
	})
}

func installProduceFault(cl *kfx.Cluster) {
	cl.ControlKey(int16(kmsg.Produce), func(req kmsg.Request) (kmsg.Response, error, bool) {
		cl.KeepControl()
		pr := req.(*kmsg.ProduceRequest)
		failTopicsMu.Lock()
		defer failTopicsMu.Unlock()
		name := func(t kmsg.ProduceRequestTopic) string {
			if t.Topic != "" {
				return t.Topic
			}
			return topicNames[t.TopicID]
		}
		hit := false
		for _, t := range pr.Topics {
			if failTopics[name(t)] {
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

// ---------- observer: wraps the REAL ProcessEvents ----------

type observer struct {
	mu         sync.Mutex
	deliveries map[int64]int
	processed  map[int64]bool // decision on the LAST delivery
}

func newObserver() *observer {
	return &observer{deliveries: map[int64]int{}, processed: map[int64]bool{}}
}

func (o *observer) wrap(next pipeline.ProcessFunc) pipeline.ProcessFunc {
	return func(ctx context.Context, recs []*kgo.Record) []*kgo.Record {
		out := next(ctx, recs)
		done := map[int64]bool{}
		for _, r := range out {
			done[r.Offset] = true
		}
		o.mu.Lock()
		for _, r := range recs {
			o.deliveries[r.Offset]++
			o.processed[r.Offset] = done[r.Offset]
		}
		o.mu.Unlock()
		return out
	}
}

// waitDelivered blocks until every offset was handed to ProcessEvents at least
// `times` times in total, or timeout.
func (o *observer) waitDelivered(offsets []int64, times int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		o.mu.Lock()
		ok := true
		for _, off := range offsets {
			if o.deliveries[off] < times {
				ok = false
			}
		}
		o.mu.Unlock()
		if ok {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("offsets %v not delivered %d time(s) within %s", offsets, times, timeout)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// ---------- scratch Postgres (db mode = the dev default; production runs cache mode: DECIDED OD-1 (owner, 2026-10-02)) ----------

const schemaSQL = `
CREATE TABLE billable_metrics (id uuid PRIMARY KEY, organization_id uuid NOT NULL, name varchar NOT NULL DEFAULT 'n',
  code varchar NOT NULL, aggregation_type int NOT NULL, recurring boolean NOT NULL DEFAULT false, field_name varchar,
  expression varchar, properties jsonb DEFAULT '{}', created_at timestamp(6) NOT NULL DEFAULT now(),
  updated_at timestamp(6) NOT NULL DEFAULT now(), deleted_at timestamp(6));
CREATE TABLE subscriptions (id uuid PRIMARY KEY, organization_id uuid NOT NULL, external_id varchar NOT NULL,
  plan_id uuid NOT NULL, status int NOT NULL DEFAULT 1, created_at timestamp(6) NOT NULL DEFAULT now(),
  updated_at timestamp(6) NOT NULL DEFAULT now(), started_at timestamp, terminated_at timestamp);
CREATE TABLE charges (id uuid PRIMARY KEY, organization_id uuid NOT NULL, plan_id uuid NOT NULL,
  billable_metric_id uuid NOT NULL, pay_in_advance boolean NOT NULL DEFAULT false,
  accepts_target_wallet boolean NOT NULL DEFAULT false, properties jsonb NOT NULL DEFAULT '{}',
  created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now(), deleted_at timestamp(6));`

func fixtureSQL() string {
	return fmt.Sprintf(`
INSERT INTO billable_metrics (id, organization_id, code, aggregation_type, field_name) VALUES
 ('%[1]s','%[2]s','api_calls',1,'amount'), ('%[3]s','%[2]s','count_calls',0,NULL);
INSERT INTO subscriptions (id, organization_id, external_id, plan_id, started_at) VALUES
 ('%[4]s','%[2]s','%[5]s','%[6]s','%[7]s');
INSERT INTO charges (id, organization_id, plan_id, billable_metric_id, pay_in_advance) VALUES
 ('%[8]s','%[2]s','%[6]s','%[1]s',true), ('%[9]s','%[2]s','%[6]s','%[3]s',false);`,
		fixture.BMSum, fixture.Org, fixture.BMCount, fixture.Sub, fixture.SubExternal, fixture.Plan,
		fixture.SubStartedAt.Format("2006-01-02 15:04:05.000000"), fixture.ChargeSumInAdvance, fixture.ChargeCount)
}

type scratchDB struct {
	admin *sql.DB
	name  string
	url   string
	role  string // throwaway connection-limited role (db-connection-exhaustion), "" if none
}

// limitedRoleURL creates a LOGIN role with CONNECTION LIMIT limit (not a superuser:
// superusers ignore the limit), grants it SELECT on the fixture tables and returns
// the scratch-database URL for it. The role is dropped by drop().
func (s *scratchDB) limitedRoleURL(limit int) (string, error) {
	name := s.name + "_conn"
	pw := fmt.Sprintf("p%x", time.Now().UnixNano())
	if _, err := s.admin.Exec(fmt.Sprintf("CREATE ROLE %s LOGIN PASSWORD '%s' CONNECTION LIMIT %d", name, pw, limit)); err != nil {
		return "", fmt.Errorf("CREATE ROLE %s: %w (role needs CREATEROLE)", name, err)
	}
	s.role = name
	db, err := sql.Open("pgx", s.url)
	if err != nil {
		return "", err
	}
	defer func() { _ = db.Close() }()
	if _, err := db.Exec("GRANT SELECT ON ALL TABLES IN SCHEMA public TO " + name); err != nil {
		return "", fmt.Errorf("GRANT SELECT to %s: %w", name, err)
	}
	u, _ := url.Parse(s.url)
	u.User = url.UserPassword(name, pw)
	return u.String(), nil
}

func createScratchDB(adminURL string) (*scratchDB, error) {
	admin, err := sql.Open("pgx", adminURL)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := admin.PingContext(ctx); err != nil {
		_ = admin.Close()
		return nil, fmt.Errorf("postgres unreachable at %s: %w (start it, see build-and-env)", redact(adminURL), err)
	}
	name := fmt.Sprintf("acct_probe_%d_%d", os.Getpid(), time.Now().Unix()%100000)
	if _, err := admin.Exec("CREATE DATABASE " + name); err != nil {
		_ = admin.Close()
		return nil, fmt.Errorf("CREATE DATABASE %s: %w (role needs CREATEDB)", name, err)
	}
	u, _ := url.Parse(adminURL)
	u.Path = "/" + name
	s := &scratchDB{admin: admin, name: name, url: u.String()}
	db, err := sql.Open("pgx", s.url)
	if err != nil {
		s.drop()
		return nil, err
	}
	defer func() { _ = db.Close() }()
	if _, err := db.Exec(schemaSQL + fixtureSQL()); err != nil {
		s.drop()
		return nil, fmt.Errorf("loading fixture schema: %w", err)
	}
	return s, nil
}

func (s *scratchDB) drop() {
	if s == nil || s.admin == nil {
		return
	}
	if _, err := s.admin.Exec("DROP DATABASE IF EXISTS " + s.name + " WITH (FORCE)"); err != nil {
		fmt.Fprintf(os.Stderr, "accounting-probe: could not drop scratch database %s: %v\n", s.name, err)
	}
	if s.role != "" {
		if _, err := s.admin.Exec("DROP ROLE IF EXISTS " + s.role); err != nil {
			fmt.Fprintf(os.Stderr, "accounting-probe: could not drop scratch role %s: %v\n", s.role, err)
		}
	}
	_ = s.admin.Close()
	s.admin = nil
}

func redact(u string) string {
	p, err := url.Parse(u)
	if err != nil {
		return "<unparsable url>"
	}
	return p.Redacted()
}

// ---------- one scenario ----------

type record struct {
	role   string
	tx     string
	offset int64
}

type row struct {
	record
	deliveries int
	processed  bool
	enriched   int
	inAdv      int
	dlq        int
	cause      string
	outcome    string
}

type caseResult struct {
	sc         scenario
	rows       []row
	committed1 int64
	committed2 int64
	sentry     int64
	zset       int
	note       string
}

func produce(ctx context.Context, cl *kfx.Cluster, payload []byte) (int64, error) {
	c, err := cl.Client()
	if err != nil {
		return 0, err
	}
	defer c.Close()
	res := c.ProduceSync(ctx, &kgo.Record{Topic: rawTopic, Value: payload})
	r, err := res.First()
	if err != nil {
		return 0, err
	}
	return r.Offset, nil
}

func runCase(sc scenario, mode, dbURL string, timeout time.Duration) (*caseResult, error) {
	ctx := context.Background()
	res := &caseResult{sc: sc}

	cl, err := kfx.Start(1, []string{rawTopic, enrichedTopic, inAdvTopic, dlqTopic})
	if err != nil {
		return nil, err
	}
	defer cl.Close()
	if err := loadTopicIDs(ctx, cl); err != nil {
		return nil, err
	}
	installProduceFault(cl)
	setFailTopics()
	subQueryFaults.Store(0)

	mr, err := miniredis.Run()
	if err != nil {
		return nil, err
	}
	defer mr.Close()

	obs := newObserver()
	cfg := pipeline.Config{
		Brokers: cl.Addrs, RawTopic: rawTopic, EnrichedTopic: enrichedTopic, InAdvanceTopic: inAdvTopic, DLQTopic: dlqTopic,
		ConsumerGroup: groupPrefix, RedisAddr: mr.Addr(), Wrap: obs.wrap,
	}
	if mode == "cache" {
		// Memory-cache mode as production runs it, minus the Debezium snapshot/CDC
		// (fixture.SeedCache writes the same tenant the DB fixture holds).
		c, err := cache.NewCache(cache.CacheConfig{Context: ctx})
		if err != nil {
			return nil, fmt.Errorf("cache.NewCache: %w", err)
		}
		defer func() { _ = c.Close() }()
		if err := fixture.SeedCache(c); err != nil {
			return nil, fmt.Errorf("fixture.SeedCache: %w", err)
		}
		cfg.Cache = c
	} else {
		u, maxConns := dbURL, int32(20)
		if sc.fault == faultConnBurst {
			u, maxConns = burstDBURL, burstPool
		}
		db, err := database.NewConnection(database.DBConfig{Url: u, MaxConns: maxConns})
		if err != nil {
			return nil, fmt.Errorf("database.NewConnection: %w", err)
		}
		defer db.Close()
		if err := registerDBFault(db.Connection); err != nil {
			return nil, err
		}
		cfg.DB = db
	}
	sentryCount.Store(0)

	var recs []record
	add := func(role, tx string, payload []byte) (int64, error) {
		off, err := produce(ctx, cl, payload)
		if err != nil {
			return 0, err
		}
		recs = append(recs, record{role: role, tx: tx, offset: off})
		return off, nil
	}

	// ---- session 1 ----
	// db-connection-exhaustion: the burst is on the topic BEFORE the consumer starts,
	// so it arrives in one poll and runs as one batch of concurrent records.
	var burstOffs []int64
	if sc.fault == faultConnBurst {
		for i := 0; i < burstSize; i++ {
			tx := fmt.Sprintf("%s-b%03d", sc.name, i)
			off, err := add("burst", tx, sc.payload(tx))
			if err != nil {
				return nil, err
			}
			burstOffs = append(burstOffs, off)
		}
	}
	p1, err := pipeline.New(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("pipeline.New: %w", err)
	}
	runCtx, stop := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() { p1.Run(runCtx); close(done) }()

	switch sc.fault {
	case faultDBSubscriptionOnce:
		subQueryFaults.Store(1)
	case faultRedisOnce:
		mr.SetError("ERR accounting-probe injected redis failure")
	case faultProduceEnriched:
		setFailTopics(enrichedTopic)
	case faultProduceDLQ:
		setFailTopics(dlqTopic)
	}
	if sc.fault == faultConnBurst {
		err = obs.waitDelivered(burstOffs, 1, timeout)
	} else {
		var fOff int64
		fOff, err = add("fault", sc.name+"-fault", sc.payload(sc.name+"-fault"))
		if err == nil {
			err = obs.waitDelivered([]int64{fOff}, 1, timeout)
		}
	}
	// disarm: the fault was transient
	subQueryFaults.Store(0)
	mr.SetError("")
	setFailTopics()
	if err == nil && sc.later {
		var o1, o2 int64
		if o1, err = add("neighbour", sc.name+"-n1", good(sc.name+"-n1")); err == nil {
			if o2, err = add("neighbour", sc.name+"-n2", good(sc.name+"-n2")); err == nil {
				err = obs.waitDelivered([]int64{o1, o2}, 1, timeout)
			}
		}
	}
	stop()
	<-done
	p1.Close()
	if err != nil {
		return nil, fmt.Errorf("session 1: %w", err)
	}
	res.committed1, _ = cl.Committed(ctx, p1.GroupID, rawTopic, 0)

	// ---- session 2: restart in the same group, then a sentinel record ----
	p2, err := pipeline.New(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("pipeline.New (restart): %w", err)
	}
	runCtx2, stop2 := context.WithCancel(ctx)
	done2 := make(chan struct{})
	go func() { p2.Run(runCtx2); close(done2) }()
	sOff, err := add("sentinel", sc.name+"-sentinel", good(sc.name+"-sentinel"))
	if err == nil {
		if _, werr := cl.WaitCommitted(ctx, p2.GroupID, rawTopic, 0, sOff+1, timeout); werr != nil {
			res.note = "sentinel not committed within timeout: " + werr.Error()
		}
	}
	stop2()
	<-done2
	p2.Close()
	if err != nil {
		return nil, fmt.Errorf("session 2: %w", err)
	}
	res.committed2, _ = cl.Committed(ctx, p2.GroupID, rawTopic, 0)
	res.sentry = sentryCount.Load()
	members, _ := mr.ZMembers(zsetName)
	res.zset = len(members)

	// ---- outputs ----
	enr, err := cl.ReadAll(ctx, enrichedTopic, timeout)
	if err != nil {
		return nil, err
	}
	adv, err := cl.ReadAll(ctx, inAdvTopic, timeout)
	if err != nil {
		return nil, err
	}
	dl, err := cl.ReadAll(ctx, dlqTopic, timeout)
	if err != nil {
		return nil, err
	}
	countTx := func(rs []*kgo.Record) map[string]int {
		m := map[string]int{}
		for _, r := range rs {
			var v struct {
				TransactionID string `json:"transaction_id"`
			}
			_ = json.Unmarshal(r.Value, &v)
			m[v.TransactionID]++
		}
		return m
	}
	enrBy, advBy := countTx(enr), countTx(adv)
	dlqBy, causeBy := map[string]int{}, map[string]string{}
	for _, r := range dl {
		var v struct {
			Event struct {
				TransactionID string `json:"transaction_id"`
			} `json:"event"`
			ErrorCode string `json:"error_code"`
			Initial   string `json:"initial_error_message"`
		}
		_ = json.Unmarshal(r.Value, &v)
		tx := v.Event.TransactionID
		if tx == "" { // unattributable DLQ record: only the fault record can fail in a case
			tx = sc.name + "-fault"
		}
		dlqBy[tx]++
		cause := v.ErrorCode
		if cause == "" {
			cause = "''"
		}
		if v.Initial != "" {
			cause += "(" + trim(v.Initial, 26) + ")"
		}
		causeBy[tx] = cause
	}

	obs.mu.Lock()
	defer obs.mu.Unlock()
	for _, r := range recs {
		rw := row{record: r, deliveries: obs.deliveries[r.offset], processed: obs.processed[r.offset],
			enriched: enrBy[r.tx], inAdv: advBy[r.tx], dlq: dlqBy[r.tx], cause: causeBy[r.tx]}
		rw.outcome = classify(rw, res.committed2)
		res.rows = append(res.rows, rw)
	}
	return res, nil
}

func classify(r row, committed int64) string {
	committedPast := committed > r.offset
	var final string
	switch {
	case r.enriched > 0 && r.dlq > 0:
		final = "ENRICHED+DLQ"
	case r.dlq > 0:
		final = "DLQ"
	case r.enriched > 0:
		final = "ENRICHED"
	}
	if !r.processed {
		if !committedPast {
			return "PENDING"
		}
		if final == "" {
			return "LOST"
		}
		return "SKIPPED_RETRY"
	}
	if final == "" {
		return "SENTRY_ONLY"
	}
	if r.deliveries > 1 {
		return "REDELIVERED"
	}
	return final
}

func loadTopicIDs(ctx context.Context, cl *kfx.Cluster) error {
	c, err := cl.Client()
	if err != nil {
		return err
	}
	defer c.Close()
	td, err := kadm.NewClient(c).ListTopics(ctx)
	if err != nil {
		return err
	}
	failTopicsMu.Lock()
	defer failTopicsMu.Unlock()
	topicNames = map[[16]byte]string{}
	for _, t := range td {
		topicNames[t.ID] = t.Topic
	}
	return nil
}

func trim(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// ---------- main ----------

func main() {
	caseFlag := flag.String("case", "", "comma-separated case names to run (default: all of the chosen -mode)")
	mode := flag.String("mode", "db", "data source: db (scratch Postgres, the dev default) or cache (memory-cache mode, as production runs it; no Postgres; cases 1-3 have no counterpart)")
	list := flag.Bool("list", false, "list cases and exit")
	def := os.Getenv("DATABASE_URL")
	if def == "" {
		def = "postgres://lago:lago@localhost:5432/lago"
	}
	dbURL := flag.String("db-url", def, "admin Postgres URL; a throwaway database is created and dropped")
	timeout := flag.Duration("timeout", 20*time.Second, "max wait per observable condition")
	verbose := flag.Bool("v", false, "show events-processor logs (default: silenced)")
	flag.Parse()

	if *mode != "db" && *mode != "cache" {
		fmt.Fprintf(os.Stderr, "accounting-probe: -mode must be db or cache, got %q\n", *mode)
		os.Exit(100)
	}
	expectedOf := func(sc scenario) string {
		if *mode == "cache" {
			return sc.cacheExp
		}
		return sc.expected
	}
	inMode := func(scs []scenario) []scenario {
		if *mode != "cache" {
			return scs
		}
		var out []scenario
		for _, sc := range scs {
			if sc.cacheExp != "" {
				out = append(out, sc)
			}
		}
		return out
	}
	pool := inMode(scenarios)
	extra := inMode(extraScenarios)
	if *list {
		for _, sc := range pool {
			fmt.Printf("%-36s %s (today: %s)\n", sc.name, sc.what, expectedOf(sc))
		}
		for _, sc := range extra {
			fmt.Printf("%-36s OPT-IN (-case only): %s (today: %s)\n", sc.name, sc.what, expectedOf(sc))
		}
		return
	}
	selected := pool
	if *caseFlag != "" {
		want := map[string]bool{}
		for _, n := range strings.Split(*caseFlag, ",") {
			want[strings.TrimSpace(n)] = true
		}
		selected = nil
		for _, sc := range append(append([]scenario{}, pool...), extra...) {
			if want[sc.name] {
				selected = append(selected, sc)
				delete(want, sc.name)
			}
		}
		if len(want) > 0 {
			fmt.Fprintf(os.Stderr, "accounting-probe: unknown case(s) for -mode %s: %v (try -mode %s -list; cases 1-3 and db-connection-exhaustion exist in db mode only)\n", *mode, keys(want), *mode)
			os.Exit(100)
		}
	}
	needBurstRole := false
	for _, sc := range selected {
		if sc.fault == faultConnBurst {
			needBurstRole = true
		}
	}

	if !*verbose {
		slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	}
	if err := sentry.Init(sentry.ClientOptions{BeforeSend: func(e *sentry.Event, _ *sentry.EventHint) *sentry.Event {
		sentryCount.Add(1)
		return nil // count only, never send
	}}); err != nil {
		fmt.Fprintln(os.Stderr, "accounting-probe: sentry init:", err)
		os.Exit(100)
	}

	var sdb *scratchDB
	dbu := ""
	if *mode == "db" {
		var err error
		sdb, err = createScratchDB(*dbURL)
		if err != nil {
			fmt.Fprintln(os.Stderr, "accounting-probe: setup error:", err)
			os.Exit(100)
		}
		dbu = sdb.url
		if needBurstRole {
			if burstDBURL, err = sdb.limitedRoleURL(connLimit); err != nil {
				sdb.drop()
				fmt.Fprintln(os.Stderr, "accounting-probe: setup error:", err)
				os.Exit(100)
			}
		}
	} else {
		fmt.Printf("== mode: cache (memory-cache data source, fixture.SeedCache; no Postgres, no CDC; %d of %d cases have a cache-mode counterpart)\n\n", len(pool), len(scenarios))
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() { <-sig; sdb.drop(); os.Exit(100) }()

	start := time.Now()
	totals := map[string]int{}
	rows := 0
	var faultLines []string
	for i, sc := range selected {
		res, err := runCase(sc, *mode, dbu, *timeout)
		if err != nil {
			sdb.drop()
			fmt.Fprintf(os.Stderr, "accounting-probe: case %s: setup error: %v\n", sc.name, err)
			os.Exit(100)
		}
		fmt.Printf("== case %d/%d %s: %s\n", i+1, len(selected), sc.name, sc.what)
		fmt.Printf("%-6s %-9s %-44s %5s %-9s %8s %6s %4s %-50s %s\n", "offset", "role", "transaction_id", "deliv", "decision", "enriched", "in_adv", "dlq", "dlq_cause", "outcome")
		burst := map[string]int{}
		for _, r := range res.rows {
			dec := "processed"
			if !r.processed {
				dec = "withheld"
			}
			cause := r.cause
			if cause == "" {
				cause = "-"
			}
			totals[r.outcome]++
			rows++
			if r.role == "burst" {
				burst[r.outcome]++
				if !*verbose { // 200 rows: aggregated below unless -v
					continue
				}
			}
			fmt.Printf("%-6d %-9s %-44s %5d %-9s %8d %6d %4d %-50s %s\n", r.offset, r.role, r.tx, r.deliveries, dec, r.enriched, r.inAdv, r.dlq, cause, r.outcome)
			if r.role == "fault" {
				faultLines = append(faultLines, fmt.Sprintf("%-36s %-14s (expected today: %s)", sc.name, r.outcome, expectedOf(sc)))
			}
		}
		if len(burst) > 0 {
			var parts []string
			for _, n := range []string{"ENRICHED", "DLQ", "REDELIVERED", "LOST", "SKIPPED_RETRY", "SENTRY_ONLY", "PENDING", "ENRICHED+DLQ"} {
				if burst[n] > 0 {
					parts = append(parts, fmt.Sprintf("%s=%d", n, burst[n]))
				}
			}
			summary := fmt.Sprintf("burst=%d %s", burstSize, strings.Join(parts, " "))
			fmt.Printf("burst rows (offsets 0-%d, -v prints each): %s\n", burstSize-1, summary)
			faultLines = append(faultLines, fmt.Sprintf("%-36s %s (expected today: %s)", sc.name, summary, expectedOf(sc)))
		}
		fmt.Printf("committed offset: after session 1 = %d, after restart = %d | sentry captures = %d | zset members = %d\n",
			res.committed1, res.committed2, res.sentry, res.zset)
		if res.note != "" {
			fmt.Println("NOTE:", res.note)
		}
		fmt.Println()
	}
	sdb.drop()

	fmt.Println("== fault-record outcome per case")
	for _, l := range faultLines {
		fmt.Println(l)
	}
	unacc := totals["LOST"] + totals["SKIPPED_RETRY"] + totals["SENTRY_ONLY"]
	names := []string{"ENRICHED", "DLQ", "REDELIVERED", "LOST", "SKIPPED_RETRY", "SENTRY_ONLY", "PENDING", "ENRICHED+DLQ"}
	parts := []string{fmt.Sprintf("rows=%d", rows)}
	for _, n := range names {
		parts = append(parts, fmt.Sprintf("%s=%d", n, totals[n]))
	}
	parts = append(parts, fmt.Sprintf("UNACCOUNTED=%d", unacc))
	fmt.Println("TOTALS " + strings.Join(parts, " "))
	fmt.Printf("elapsed: %s\n", time.Since(start).Round(100*time.Millisecond))
	if unacc > 99 {
		unacc = 99
	}
	os.Exit(unacc)
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
