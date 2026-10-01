// value-format-probe: drives the REAL events-processor enrichment path
// (json.Unmarshal into models.Event, then EventEnrichmentService.EnrichEvent with an
// in-memory cache) over a golden property corpus and prints the `value` string Go
// produces, next to what the enriched JSON carries in `properties`.
//
// Needs CGO (the enrichment package links libexpression_go). From the repo root:
//
//	source .claude/skills/build-and-env/scripts/ep-env.sh
//	cd .claude/skills/rails-go-parity/scripts && go run ./value-format-probe
//	go run ./value-format-probe -values-only   # one Go value per line (pipe into ch-decimal-probe.sh -)
//
// Exit codes: 0 = report printed; 1 = setup error (cache, enrichment failure on a value case).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/config/kafka"
	"github.com/getlago/lago/events-processor/models"
	ep "github.com/getlago/lago/events-processor/processors/events_processor"
	"github.com/getlago/lago/events-processor/utils"
)

const (
	org  = "org-probe"
	extS = "sub-probe"
)

type vcase struct {
	label string
	prop  string // raw JSON for properties.amount; "" = key absent
}

var corpus = []vcase{
	{"999999", "999999"},
	{"1000000", "1000000"},
	{"12345678", "12345678"},
	{"1e20", "1e20"},
	{"1e21", "1e21"},
	{"0.1", "0.1"},
	{"1e-7", "1e-7"},
	{"2^53+1", "9007199254740993"},
	{"null", "null"},
	{"missing", ""},
	{"true", "true"},
	{`"12" (string)`, `"12"`},
	{`"1000000" (string)`, `"1000000"`},
	{"2.0", "2.0"},
	{"1234567.5", "1234567.5"},
	{"object", `{"x":1}`},
}

func rawEvent(tx, code, source, props string) []byte {
	// Shape of Rails Events::KafkaProducerService#build_payload (CH-store org).
	return []byte(fmt.Sprintf(`{"organization_id":%q,"external_customer_id":"cust-probe","external_subscription_id":%q,`+
		`"transaction_id":%q,"timestamp":"1741007009.123","code":%q,"precise_total_amount_cents":"0.0",`+
		`"properties":%s,"ingested_at":"2025-03-03T13:03:30.456","source":%q,"source_metadata":{"api_post_processed":false}}`,
		org, extS, tx, code, props, source))
}

func main() {
	valuesOnly := flag.Bool("values-only", false, "print only the Go value string per corpus case, one per line")
	flag.Parse()
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))

	c, err := cache.NewCache(cache.CacheConfig{Context: context.Background()})
	if err != nil {
		fmt.Fprintln(os.Stderr, "cache:", err)
		os.Exit(1)
	}
	defer c.Close()

	bms := []*models.BillableMetric{
		{ID: "bm-sum", OrganizationID: org, Code: "probe_sum", AggregationType: models.AggregationTypeSum, FieldName: "amount"},
		{ID: "bm-uc", OrganizationID: org, Code: "probe_uc", AggregationType: models.AggregationTypeUniqueCount, FieldName: "amount"},
		{ID: "bm-expr", OrganizationID: org, Code: "probe_expr", AggregationType: models.AggregationTypeSum, FieldName: "amount", Expression: "event.timestamp"},
	}
	for _, bm := range bms {
		if r := c.SetBillableMetric(bm); r.Failure() {
			fmt.Fprintln(os.Stderr, "set bm:", r.Error())
			os.Exit(1)
		}
	}
	svc := ep.NewEventEnrichmentService(nil, c)

	enrich := func(raw []byte) (*models.EnrichedEvent, string, error) {
		var ev models.Event
		if err := json.Unmarshal(raw, &ev); err != nil { // processor.go ProcessEvents does exactly this
			return nil, "", err
		}
		r := svc.EnrichEvent(&ev)
		if r.Failure() {
			return nil, r.ErrorCode(), r.Error()
		}
		return r.Value(), "", nil
	}

	if !*valuesOnly {
		fmt.Println("# value-format-probe: Go EnrichedEvent.value for properties.amount (BM sum, field_name=amount, source=http_ruby)")
		fmt.Println("case\traw_json\tgo_value\tenriched_properties.amount")
	}
	for i, vc := range corpus {
		props := `{}`
		if vc.prop != "" {
			props = `{"amount":` + vc.prop + `}`
		}
		e, code, err := enrich(rawEvent(fmt.Sprintf("tx-%d", i), "probe_sum", "http_ruby", props))
		if err != nil {
			fmt.Fprintf(os.Stderr, "case %s: enrichment failed code=%s err=%v\n", vc.label, code, err)
			os.Exit(1)
		}
		if *valuesOnly {
			fmt.Println(*e.Value)
			continue
		}
		pj := "(absent)"
		if v, ok := e.Properties["amount"]; ok {
			b, _ := json.Marshal(v)
			pj = string(b)
		}
		raw := vc.prop
		if raw == "" {
			raw = "(absent)"
		}
		fmt.Printf("%s\t%s\t%q\t%s\n", vc.label, raw, *e.Value, pj)
	}
	if *valuesOnly {
		return
	}

	// unique_count uses the same value string (ClickHouse compares it raw).
	a, _, _ := enrich(rawEvent("tx-uc-1", "probe_uc", "http_ruby", `{"amount":1000000}`))
	b, _, _ := enrich(rawEvent("tx-uc-2", "probe_uc", "http_ruby", `{"amount":"1000000"}`))
	if a != nil && b != nil {
		fmt.Printf("unique_count: number 1000000 -> %q ; string \"1000000\" (re-enrichment form) -> %q ; same unique in CH: %t\n",
			*a.Value, *b.Value, *a.Value == *b.Value)
	}

	// Expression engine: event.timestamp as Go passes it (Rails passes timestamp.to_i).
	x, code, err := enrich(rawEvent("tx-expr-1", "probe_expr", "connector", `{"amount":1}`))
	if err == nil {
		fmt.Printf("expression event.timestamp (source!=http_ruby, ts \"1741007009.123\") -> value %q (Rails Lago::Event gets 1741007009)\n", *x.Value)
	} else {
		fmt.Printf("expression event.timestamp -> error code=%s err=%v\n", code, err)
	}
	_, code, err = enrich(rawEvent("tx-expr-2", "probe_expr", "connector", `null`))
	fmt.Printf("expression with properties:null (source!=http_ruby) -> error_code=%q failed=%t\n", code, err != nil)

	// connectors/*.yml pass a numeric precise_total_amount_cents through unchanged.
	var cev models.Event
	cerr := json.Unmarshal([]byte(`{"organization_id":"o","external_subscription_id":"s","transaction_id":"t","code":"probe_sum",`+
		`"timestamp":1741007009,"properties":{},"ingested_at":1741007010,"precise_total_amount_cents":100}`), &cev)
	fmt.Printf("connector payload with numeric precise_total_amount_cents -> unmarshal error: %v\n", cerr)

	// Wire format: the REAL EventProducerService writing into a capturing producer.
	capture := &capProducer{}
	prod := ep.NewEventProducerService(capture, capture, capture)
	raw := rawEvent("tx-wire", "probe_sum", "http_ruby", `{"amount":9007199254740993,"region":"eu"}`)
	var ev models.Event
	_ = json.Unmarshal(raw, &ev)
	w, _, werr := enrich(raw)
	if werr == nil {
		prod.ProduceEnrichedEvent(context.Background(), w)
	}
	prod.ProduceToDeadLetterQueue(context.Background(), ev, utils.FailedBoolResult(errors.New("record not found")).AddErrorDetails("fetch_billable_metric", "Error fetching billable metric"))
	fmt.Printf("wire raw-in   value=%s\n", raw)
	for _, m := range capture.msgs {
		fmt.Printf("wire %-9s key=%q value=%s\n", m.kind, m.key, m.value)
	}
}

type capMsg struct{ kind, key, value string }
type capProducer struct{ msgs []capMsg }

func (p *capProducer) Produce(_ context.Context, m *kafka.ProducerMessage) bool {
	kind := "enriched"
	if m.Key == nil {
		kind = "dlq"
	}
	p.msgs = append(p.msgs, capMsg{kind, string(m.Key), string(m.Value)})
	return true
}
func (p *capProducer) GetTopic() string { return "capture" }
