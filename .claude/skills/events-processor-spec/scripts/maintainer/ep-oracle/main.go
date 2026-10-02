// MAINTAINER-ONLY: needs the lago repository (events-processor tree 83e012866f29) and the Go/CGO toolchain; excluded from clean-room packs.
//
// ep-oracle answers the kit's ep.* unit ops over the adapter protocol v1 (JSON lines on
// stdin/stdout) by calling the reference events-processor packages. It is compiled inside a
// read-only export of the events-processor tree by build-go-reference.sh (which adds this
// file as cmd/ep-oracle/main.go). It declares the compat profile only: the reference does
// not implement the corrected profile.
//
// Ops (input -> output; see reference/processing-rules.md "Unit ops"):
//
//	ep.decode            {raw_b64}                                         -> {event, event_json} | error undecodable
//	ep.parse_timestamp   {timestamp_json}                                  -> {emitted_text, match_time, match_instant} | error invalid_timestamp
//	ep.value_string      {aggregation_type ("<stored code>"), field_name?, properties_json}
//	                                                                       -> {value, aggregation_label} | error undecodable
//	ep.match_subscription {mode, external_subscription_id, timestamp_json, recurring, now, subscriptions[]}
//	                                                                       -> {subscription_id, plan_id} | error <dlq code>
//	ep.commit_offset     {records:[{offset, processed}], pending_before?}  -> {commit}
//	ep.refresh_member    {organization_id, subscription_id, now_unix}      -> {member, score}
//	expression.evaluate  {expression, event:{code, timestamp_seconds, properties_json}, mode:"ep"} -> {value} | error evaluation_error
//
// DB-mode subscription matching needs Postgres: EP_ORACLE_PG_ADMIN_URL (default
// postgres://lago:lago@localhost:5432/lago); a scratch database ep_oracle_<pid> is created on
// first use and dropped at exit. Everything else runs in memory (badger cache, miniredis).
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/jackc/pgx/v5"
	goredis "github.com/redis/go-redis/v9"
	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/config/database"
	"github.com/getlago/lago/events-processor/config/kafka"
	"github.com/getlago/lago/events-processor/config/redis"
	"github.com/getlago/lago/events-processor/models"
	ep "github.com/getlago/lago/events-processor/processors/events_processor"
	"github.com/getlago/lago/events-processor/utils"
)

type msg struct {
	Type    string          `json:"type"`
	Proto   int             `json:"proto"`
	ID      string          `json:"id"`
	Area    string          `json:"area"`
	Op      string          `json:"op"`
	Profile string          `json:"profile"`
	Input   json.RawMessage `json:"input"`
}

type kitErr struct {
	Code    string `json:"code"`
	Field   string `json:"field,omitempty"`
	Message string `json:"message,omitempty"`
}

func (e *kitErr) Error() string { return e.Code + ": " + e.Message }

var ops = []string{"ep.decode", "ep.parse_timestamp", "ep.value_string", "ep.match_subscription",
	"ep.commit_offset", "ep.refresh_member", "expression.evaluate"}

func main() {
	defer cleanupDB()
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 1<<20), 16<<20)
	out := bufio.NewWriter(os.Stdout)
	send := func(v any) {
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(v)
		out.Write(buf.Bytes())
		out.Flush()
	}
	for in.Scan() {
		var m msg
		if err := json.Unmarshal(in.Bytes(), &m); err != nil {
			fmt.Fprintln(os.Stderr, "ep-oracle: bad request line:", err)
			continue
		}
		switch m.Type {
		case "hello":
			send(map[string]any{"type": "hello", "proto": 1, "impl": "ep-oracle", "impl_version": "ep:" + treeID(),
				"profiles": []string{"compat"}, "ops": ops})
		case "bye":
			return
		case "call":
			res, err := dispatch(m)
			if err != nil {
				ke, ok := err.(*kitErr)
				if !ok {
					ke = &kitErr{Code: "internal", Message: err.Error()}
				}
				send(map[string]any{"type": "result", "id": m.ID, "error": ke})
				continue
			}
			send(map[string]any{"type": "result", "id": m.ID, "output": res})
		default:
			fmt.Fprintln(os.Stderr, "ep-oracle: unknown message type", m.Type)
		}
	}
}

func treeID() string {
	if exe, err := os.Executable(); err == nil {
		if b, err := os.ReadFile(strings.TrimSuffix(exe, "ep-oracle") + ".tree"); err == nil {
			return strings.TrimSpace(string(b))
		}
	}
	return "unknown"
}

func dispatch(m msg) (any, error) {
	if m.Profile != "" && m.Profile != "compat" {
		return nil, &kitErr{Code: "unsupported_op", Message: "the reference implements the compat profile only"}
	}
	d := json.NewDecoder(bytes.NewReader(m.Input))
	d.UseNumber()
	var in map[string]any
	if err := d.Decode(&in); err != nil {
		return nil, &kitErr{Code: "bad_input", Message: err.Error()}
	}
	switch m.Area + "." + m.Op {
	case "ep.decode":
		return opDecode(in)
	case "ep.parse_timestamp":
		return opParseTimestamp(in)
	case "ep.value_string":
		return opValueString(in)
	case "ep.match_subscription":
		return opMatchSubscription(in)
	case "ep.commit_offset":
		return opCommitOffset(in)
	case "ep.refresh_member":
		return opRefreshMember(in)
	case "expression.evaluate":
		return opExpression(in)
	}
	return nil, &kitErr{Code: "unsupported_op", Message: m.Area + "." + m.Op}
}

// ------------------------------------------------------------------ helpers

func str(in map[string]any, k string) (string, bool) {
	v, ok := in[k]
	if !ok || v == nil {
		return "", false
	}
	s, ok := v.(string)
	return s, ok
}

// canon re-encodes JSON with sorted keys, number literals preserved and no HTML escaping
// (the suite's canonical form).
func canon(b []byte) (string, error) {
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return "", err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return "", err
	}
	return strings.TrimRight(buf.String(), "\n"), nil
}

// rawEvent builds the raw-topic JSON of an event from literal field texts.
func rawEvent(fields map[string]string) []byte {
	keys := make([]string, 0, len(fields))
	for k := range fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString("{")
	for i, k := range keys {
		if i > 0 {
			b.WriteString(",")
		}
		kb, _ := json.Marshal(k)
		b.Write(kb)
		b.WriteString(":")
		b.WriteString(fields[k])
	}
	b.WriteString("}")
	return []byte(b.String())
}

func q(s string) string { b, _ := json.Marshal(s); return string(b) }

func resultErr(r utils.AnyResult) error {
	return &kitErr{Code: r.ErrorCode(), Message: r.ErrorMsg()}
}

// ------------------------------------------------------------------ ep.decode

func opDecode(in map[string]any) (any, error) {
	var raw []byte
	if s, ok := str(in, "raw_b64"); ok {
		b, err := base64.StdEncoding.DecodeString(s)
		if err != nil {
			return nil, &kitErr{Code: "bad_input", Field: "raw_b64", Message: err.Error()}
		}
		raw = b
	} else {
		return nil, &kitErr{Code: "bad_input", Field: "raw_b64", Message: "raw_b64 required"}
	}
	var ev models.Event
	if err := json.Unmarshal(raw, &ev); err != nil {
		return nil, &kitErr{Code: "undecodable", Message: err.Error()}
	}
	b, err := json.Marshal(ev)
	if err != nil {
		return nil, err
	}
	c, err := canon(b)
	if err != nil {
		return nil, err
	}
	d := json.NewDecoder(strings.NewReader(c))
	d.UseNumber()
	var obj any
	_ = d.Decode(&obj)
	return map[string]any{"event": obj, "event_json": c}, nil
}

// ------------------------------------------------------------------ ep.parse_timestamp

func opParseTimestamp(in map[string]any) (any, error) {
	fields := map[string]string{}
	if s, ok := str(in, "timestamp_json"); ok {
		fields["timestamp"] = s
	}
	var ev models.Event
	if err := json.Unmarshal(rawEvent(fields), &ev); err != nil {
		return nil, &kitErr{Code: "undecodable", Message: err.Error()}
	}
	r := ev.ToEnrichedEvent()
	if r.Failure() {
		return nil, &kitErr{Code: "invalid_timestamp", Field: "timestamp", Message: r.ErrorMsg()}
	}
	er := r.Value()
	b, err := json.Marshal(er)
	if err != nil {
		return nil, err
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var obj map[string]any
	if err := d.Decode(&obj); err != nil {
		return nil, err
	}
	emitted := fmt.Sprint(obj["timestamp"])
	return map[string]any{
		"emitted_text":  emitted,
		"match_time":    er.Time.Format(time.RFC3339Nano),
		"match_instant": er.Time.UTC().Format(time.RFC3339Nano),
	}, nil
}

// ------------------------------------------------------------------ ep.value_string

func newMemCache() (*cache.Cache, error) {
	return cache.NewCache(cache.CacheConfig{Context: context.Background()})
}

func intIn(in map[string]any, k string) (int64, bool) {
	v, ok := in[k].(json.Number)
	if !ok {
		return 0, false
	}
	n, err := v.Int64()
	return n, err == nil
}

func opValueString(in map[string]any) (any, error) {
	// aggregation_type is the stored integer code written as a decimal string ("1"); a bare
	// JSON integer is accepted too.
	agg, ok := intIn(in, "aggregation_type")
	if !ok {
		s, _ := str(in, "aggregation_type")
		n, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			return nil, &kitErr{Code: "bad_input", Field: "aggregation_type", Message: "stored integer code required"}
		}
		agg = n
	}
	field, _ := str(in, "field_name")
	c, err := newMemCache()
	if err != nil {
		return nil, err
	}
	defer c.Close()
	const org = "00000000-0000-0000-0000-0000000000aa"
	bm := &models.BillableMetric{ID: "00000000-0000-0000-0000-0000000000bb", OrganizationID: org, Code: "metric_under_test",
		AggregationType: models.AggregationType(agg), FieldName: field}
	if r := c.SetBillableMetric(bm); r.Failure() {
		return nil, r.Error()
	}
	fields := map[string]string{"organization_id": q(org), "code": q(bm.Code), "transaction_id": q("tx"),
		"external_subscription_id": q("none"), "timestamp": "1759320000"}
	if s, ok := str(in, "properties_json"); ok {
		fields["properties"] = s
	}
	var ev models.Event
	if err := json.Unmarshal(rawEvent(fields), &ev); err != nil {
		return nil, &kitErr{Code: "undecodable", Message: err.Error()}
	}
	svc := ep.NewEventEnrichmentService(nil, c)
	r := svc.EnrichEvent(&ev)
	if r.Failure() {
		return nil, resultErr(r)
	}
	er := r.Value()
	val := ""
	if er.Value != nil {
		val = *er.Value
	}
	return map[string]any{"value": val, "aggregation_label": er.AggregationType}, nil
}

// ------------------------------------------------------------------ ep.match_subscription

var (
	pgDB    *database.DB
	pgURL   string
	pgName  string
	pgAdmin string
)

const oracleSchema = `
CREATE TABLE billable_metrics (id uuid PRIMARY KEY, organization_id uuid NOT NULL, code varchar NOT NULL,
  aggregation_type int NOT NULL, recurring boolean NOT NULL DEFAULT false, field_name varchar, expression varchar,
  created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now(), deleted_at timestamp(6));
CREATE TABLE subscriptions (id uuid PRIMARY KEY, organization_id uuid NOT NULL, external_id varchar NOT NULL,
  plan_id uuid NOT NULL, status int NOT NULL DEFAULT 1, created_at timestamp(6) NOT NULL DEFAULT now(),
  updated_at timestamp(6) NOT NULL DEFAULT now(), started_at timestamp, terminated_at timestamp);
CREATE TABLE charges (id uuid PRIMARY KEY, organization_id uuid NOT NULL, plan_id uuid, billable_metric_id uuid,
  pay_in_advance boolean NOT NULL DEFAULT false, accepts_target_wallet boolean NOT NULL DEFAULT false,
  properties jsonb NOT NULL DEFAULT '{}', created_at timestamp(6) NOT NULL DEFAULT now(),
  updated_at timestamp(6) NOT NULL DEFAULT now(), deleted_at timestamp(6));`

func ensureDB() error {
	if pgDB != nil {
		return nil
	}
	pgAdmin = os.Getenv("EP_ORACLE_PG_ADMIN_URL")
	if pgAdmin == "" {
		pgAdmin = "postgres://lago:lago@localhost:5432/lago"
	}
	ctx := context.Background()
	ac, err := pgx.Connect(ctx, pgAdmin)
	if err != nil {
		return err
	}
	defer ac.Close(ctx)
	pgName = fmt.Sprintf("ep_oracle_%d", os.Getpid())
	if _, err := ac.Exec(ctx, fmt.Sprintf(`DROP DATABASE IF EXISTS "%s" WITH (FORCE)`, pgName)); err != nil {
		return err
	}
	if _, err := ac.Exec(ctx, fmt.Sprintf(`CREATE DATABASE "%s"`, pgName)); err != nil {
		return err
	}
	cfg, err := pgx.ParseConfig(pgAdmin)
	if err != nil {
		return err
	}
	cfg.Database = pgName
	pgURL = fmt.Sprintf("postgres://%s:%s@%s:%d/%s", cfg.User, cfg.Password, cfg.Host, cfg.Port, pgName)
	sc, err := pgx.Connect(ctx, pgURL)
	if err != nil {
		return err
	}
	_, err = sc.Exec(ctx, oracleSchema)
	sc.Close(ctx)
	if err != nil {
		return err
	}
	pgDB, err = database.NewConnection(database.DBConfig{Url: pgURL, MaxConns: 2})
	return err
}

func cleanupDB() {
	if pgDB == nil {
		return
	}
	pgDB.Close()
	ctx := context.Background()
	if ac, err := pgx.Connect(ctx, pgAdmin); err == nil {
		_, _ = ac.Exec(ctx, fmt.Sprintf(`DROP DATABASE IF EXISTS "%s" WITH (FORCE)`, pgName))
		ac.Close(ctx)
	}
}

func parseInst(s string) (time.Time, error) {
	return time.Parse(time.RFC3339Nano, s)
}

type subIn struct {
	ID             string  `json:"id"`
	OrganizationID string  `json:"organization_id"`
	ExternalID     string  `json:"external_id"`
	PlanID         string  `json:"plan_id"`
	Status         int     `json:"status"`
	StartedAt      string  `json:"started_at"`
	TerminatedAt   *string `json:"terminated_at"`
}

const defaultOrg = "11111111-1111-1111-1111-111111111111"
const defaultPlan = "22222222-2222-2222-2222-222222222222"

func opMatchSubscription(in map[string]any) (any, error) {
	mode, _ := str(in, "mode")
	if mode != "db" && mode != "cache" {
		return nil, &kitErr{Code: "bad_input", Field: "mode", Message: "db or cache"}
	}
	org, ok := str(in, "organization_id")
	if !ok {
		org = defaultOrg
	}
	ext, _ := str(in, "external_subscription_id")
	recurring, _ := in["recurring"].(bool)
	rawSubs, _ := json.Marshal(in["subscriptions"])
	var subs []subIn
	if err := json.Unmarshal(rawSubs, &subs); err != nil {
		return nil, &kitErr{Code: "bad_input", Field: "subscriptions", Message: err.Error()}
	}
	bm := &models.BillableMetric{ID: "aaaaaaaa-0000-0000-0000-0000000000ee", OrganizationID: org, Code: "metric_under_test",
		AggregationType: models.AggregationTypeCount, Recurring: recurring}
	fields := map[string]string{"organization_id": q(org), "code": q(bm.Code), "transaction_id": q("tx"),
		"external_subscription_id": q(ext)}
	if s, ok := str(in, "timestamp_json"); ok {
		fields["timestamp"] = s
	}
	var ev models.Event
	if err := json.Unmarshal(rawEvent(fields), &ev); err != nil {
		return nil, &kitErr{Code: "undecodable", Message: err.Error()}
	}
	var svc *ep.EventEnrichmentService
	if mode == "cache" {
		c, err := newMemCache()
		if err != nil {
			return nil, err
		}
		defer c.Close()
		if r := c.SetBillableMetric(bm); r.Failure() {
			return nil, r.Error()
		}
		for _, s := range subs {
			o := s.OrganizationID
			if o == "" {
				o = org
			}
			plan := s.PlanID
			if plan == "" {
				plan = defaultPlan
			}
			ms := &models.Subscription{ID: s.ID, OrganizationID: &o, ExternalID: s.ExternalID, PlanID: plan}
			t, err := parseInst(s.StartedAt)
			if err != nil {
				return nil, &kitErr{Code: "bad_input", Field: "started_at", Message: err.Error()}
			}
			ms.StartedAt = utils.NewNullTime(t.UTC())
			if s.TerminatedAt != nil {
				tt, err := parseInst(*s.TerminatedAt)
				if err != nil {
					return nil, &kitErr{Code: "bad_input", Field: "terminated_at", Message: err.Error()}
				}
				ms.TerminatedAt = utils.NewNullTime(tt.UTC())
			}
			if r := c.SetSubscription(ms); r.Failure() {
				return nil, r.Error()
			}
		}
		svc = ep.NewEventEnrichmentService(nil, c)
	} else {
		if err := ensureDB(); err != nil {
			return nil, &kitErr{Code: "internal", Message: "postgres: " + err.Error()}
		}
		ctx := context.Background()
		cn, err := pgx.Connect(ctx, pgURL)
		if err != nil {
			return nil, err
		}
		defer cn.Close(ctx)
		if _, err := cn.Exec(ctx, "DELETE FROM subscriptions; DELETE FROM billable_metrics; DELETE FROM charges"); err != nil {
			return nil, err
		}
		if _, err := cn.Exec(ctx, "INSERT INTO billable_metrics (id, organization_id, code, aggregation_type, recurring) VALUES ($1,$2,$3,0,$4)",
			bm.ID, org, bm.Code, recurring); err != nil {
			return nil, err
		}
		wall := func(s string) (string, error) {
			t, err := parseInst(s)
			if err != nil {
				return "", err
			}
			return t.UTC().Format("2006-01-02 15:04:05.999999"), nil
		}
		for _, s := range subs {
			o := s.OrganizationID
			if o == "" {
				o = org
			}
			plan := s.PlanID
			if plan == "" {
				plan = defaultPlan
			}
			st, err := wall(s.StartedAt)
			if err != nil {
				return nil, &kitErr{Code: "bad_input", Field: "started_at", Message: err.Error()}
			}
			var term any
			if s.TerminatedAt != nil {
				tt, err := wall(*s.TerminatedAt)
				if err != nil {
					return nil, &kitErr{Code: "bad_input", Field: "terminated_at", Message: err.Error()}
				}
				term = tt
			}
			if _, err := cn.Exec(ctx, "INSERT INTO subscriptions (id, organization_id, external_id, plan_id, status, started_at, terminated_at) VALUES ($1,$2,$3,$4,$5,$6::timestamp,$7::timestamp)",
				s.ID, o, s.ExternalID, plan, s.Status, st, term); err != nil {
				return nil, err
			}
		}
		svc = ep.NewEventEnrichmentService(models.NewApiStore(pgDB), nil)
	}
	r := svc.EnrichEvent(&ev)
	if r.Failure() {
		return nil, resultErr(r)
	}
	er := r.Value()
	return map[string]any{"subscription_id": er.SubscriptionID, "plan_id": er.PlanID}, nil
}

// ------------------------------------------------------------------ ep.commit_offset

func opCommitOffset(in map[string]any) (any, error) {
	raw, _ := json.Marshal(in["records"])
	var recs []struct {
		Offset    int64 `json:"offset"`
		Processed bool  `json:"processed"`
	}
	if err := json.Unmarshal(raw, &recs); err != nil || len(recs) == 0 {
		return nil, &kitErr{Code: "bad_input", Field: "records", Message: "non-empty array of {offset, processed}"}
	}
	var all, done []*kgo.Record
	for _, r := range recs {
		k := &kgo.Record{Topic: "events-raw", Partition: 0, Offset: r.Offset}
		all = append(all, k)
		if r.Processed {
			done = append(done, k)
		}
	}
	// Batch commit as the consumer performs it: all processed -> commit after the last record;
	// otherwise commit after the record chosen by the reference selection, or nothing.
	if len(done) == len(all) {
		max := all[0].Offset
		for _, r := range all {
			if r.Offset > max {
				max = r.Offset
			}
		}
		return map[string]any{"commit": max + 1}, nil
	}
	rec, ok := kafka.OracleFindMaxCommitableRecord(done, all)
	if !ok {
		return map[string]any{"commit": nil}, nil
	}
	return map[string]any{"commit": rec.Offset + 1}, nil
}

// ------------------------------------------------------------------ ep.refresh_member

func opRefreshMember(in map[string]any) (any, error) {
	org, _ := str(in, "organization_id")
	sub, _ := str(in, "subscription_id")
	now, ok := intIn(in, "now_unix")
	if !ok {
		return nil, &kitErr{Code: "bad_input", Field: "now_unix", Message: "integer required"}
	}
	mr, err := miniredis.Run()
	if err != nil {
		return nil, err
	}
	defer mr.Close()
	client := goredis.NewClient(&goredis.Options{Addr: mr.Addr()})
	defer client.Close()
	store := models.NewFlagStore(&redis.RedisDB{Client: client}, "subscription_refreshed_v2")
	svc := ep.NewSubscriptionRefreshService(store)
	before := time.Now().Unix()
	if r := svc.FlagSubscriptionRefresh(context.Background(), &models.EnrichedEvent{OrganizationID: org, SubscriptionID: sub}); r.Failure() {
		return nil, resultErr(r)
	}
	after := time.Now().Unix()
	members, err := mr.ZMembers("subscription_refreshed_v2")
	if err != nil || len(members) != 1 {
		return nil, fmt.Errorf("expected one member, got %v (%v)", members, err)
	}
	score, _ := mr.ZScore("subscription_refreshed_v2", members[0])
	i := strings.LastIndex(members[0], "|")
	prefix, bucketText := members[0][:i], members[0][i+1:]
	bucket, _ := strconv.ParseInt(bucketText, 10, 64)
	sc := int64(score)
	// Self-check of the live write: score = wall-clock seconds, bucket = score floored to 10 s.
	if sc < before || sc > after || bucket != sc/10*10 {
		return nil, fmt.Errorf("live flag write violates the bucket rule: member=%s score=%v", members[0], score)
	}
	// Map the observed rule onto the requested clock.
	return map[string]any{"member": prefix + "|" + strconv.FormatInt(now/10*10, 10), "score": now}, nil
}

// ------------------------------------------------------------------ expression.evaluate (mode ep)

func opExpression(in map[string]any) (any, error) {
	if m, _ := str(in, "mode"); m != "ep" {
		return nil, &kitErr{Code: "unsupported_op", Message: "ep-oracle answers mode ep only"}
	}
	expr, _ := str(in, "expression")
	evIn, _ := in["event"].(map[string]any)
	if evIn == nil {
		return nil, &kitErr{Code: "bad_input", Field: "event"}
	}
	code, _ := str(evIn, "code")
	if code == "" {
		code = "metric_under_test"
	}
	c, err := newMemCache()
	if err != nil {
		return nil, err
	}
	defer c.Close()
	const org = "00000000-0000-0000-0000-0000000000aa"
	bm := &models.BillableMetric{ID: "00000000-0000-0000-0000-0000000000cc", OrganizationID: org, Code: code,
		AggregationType: models.AggregationTypeSum, FieldName: "kit_expression_result", Expression: expr}
	if r := c.SetBillableMetric(bm); r.Failure() {
		return nil, r.Error()
	}
	fields := map[string]string{"organization_id": q(org), "code": q(code), "transaction_id": q("tx"),
		"external_subscription_id": q("none")}
	switch ts := evIn["timestamp_seconds"].(type) {
	case json.Number:
		fields["timestamp"] = ts.String()
	case string:
		fields["timestamp"] = q(ts)
	default:
		fields["timestamp"] = "1759320000"
	}
	if s, ok := str(evIn, "properties_json"); ok {
		fields["properties"] = s
	} else {
		fields["properties"] = "{}"
	}
	var ev models.Event
	if err := json.Unmarshal(rawEvent(fields), &ev); err != nil {
		return nil, &kitErr{Code: "bad_input", Message: err.Error()}
	}
	r := ep.NewEventEnrichmentService(nil, c).EnrichEvent(&ev)
	if r.Failure() {
		if r.ErrorCode() == "evaluate_expression" {
			return nil, &kitErr{Code: "evaluation_error", Message: r.ErrorMsg()}
		}
		return nil, resultErr(r)
	}
	v, _ := r.Value().Properties[bm.FieldName].(string)
	return map[string]any{"value": v}, nil
}
