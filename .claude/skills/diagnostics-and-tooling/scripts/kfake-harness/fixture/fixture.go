// Package fixture holds one tiny, deterministic Lago tenant shared by every
// harness scenario. The SAME ids and rows are in ../../fixtures/smoke-schema.sql,
// so DB mode (scratch Postgres loaded from that file) and memory-cache mode
// (SeedCache below) see identical data. Change both together.
//
// No CGO needed.
package fixture

import (
	"database/sql"
	"encoding/json"
	"time"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

const (
	Org  = "11111111-1111-1111-1111-111111111111"
	Plan = "22222222-2222-2222-2222-222222222222"

	BMSum   = "aaaaaaaa-0000-0000-0000-000000000001" // code api_calls, sum of "amount"
	BMCount = "aaaaaaaa-0000-0000-0000-000000000002" // code count_calls, count
	BMExpr  = "aaaaaaaa-0000-0000-0000-000000000003" // code expr_metric, sum of "total", expression event.properties.a * 2

	Sub         = "bbbbbbbb-0000-0000-0000-000000000001"
	SubExternal = "sub_ext_1"

	ChargeSumInAdvance = "cccccccc-0000-0000-0000-000000000001" // pay_in_advance = true  (api_calls)
	ChargeCount        = "cccccccc-0000-0000-0000-000000000002" // pay_in_advance = false (count_calls)
)

// SubStartedAt is the subscription start, deliberately carrying 500 µs so
// that millisecond-vs-microsecond comparisons are observable.
var SubStartedAt = time.Date(2025, 1, 1, 0, 0, 0, 500_000, time.UTC)

func nt(t time.Time) utils.NullTime {
	return utils.NullTime{NullTime: sql.NullTime{Time: t, Valid: true}}
}

// SeedCache writes the fixture tenant into a memory cache (memory-cache mode
// without Postgres or Debezium).
func SeedCache(c *cache.Cache) error {
	org := Org
	now := nt(time.Now().UTC())
	bms := []models.BillableMetric{
		{ID: BMSum, OrganizationID: Org, Code: "api_calls", AggregationType: models.AggregationTypeSum, FieldName: "amount", CreatedAt: now, UpdatedAt: now},
		{ID: BMCount, OrganizationID: Org, Code: "count_calls", AggregationType: models.AggregationTypeCount, CreatedAt: now, UpdatedAt: now},
		{ID: BMExpr, OrganizationID: Org, Code: "expr_metric", AggregationType: models.AggregationTypeSum, FieldName: "total", Expression: "event.properties.a * 2", CreatedAt: now, UpdatedAt: now},
	}
	for i := range bms {
		if r := c.SetBillableMetric(&bms[i]); r.Failure() {
			return r.Error()
		}
	}
	sub := models.Subscription{ID: Sub, OrganizationID: &org, ExternalID: SubExternal, PlanID: Plan, CreatedAt: now, UpdatedAt: now, StartedAt: nt(SubStartedAt)}
	if r := c.SetSubscription(&sub); r.Failure() {
		return r.Error()
	}
	charges := []models.Charge{
		{ID: ChargeSumInAdvance, OrganizationID: Org, PlanID: Plan, BillableMetricID: BMSum, PayInAdvance: true, CreatedAt: now, UpdatedAt: now},
		{ID: ChargeCount, OrganizationID: Org, PlanID: Plan, BillableMetricID: BMCount, CreatedAt: now, UpdatedAt: now},
	}
	for i := range charges {
		if r := c.SetCharge(&charges[i]); r.Failure() {
			return r.Error()
		}
	}
	return nil
}

// RawEvent is the raw-topic payload shape (models.Event JSON tags). Zero
// fields are omitted so scenarios can build malformed events on purpose.
type RawEvent struct {
	OrganizationID         string         `json:"organization_id,omitempty"`
	ExternalSubscriptionID string         `json:"external_subscription_id,omitempty"`
	TransactionID          string         `json:"transaction_id,omitempty"`
	Code                   string         `json:"code,omitempty"`
	Properties             map[string]any `json:"properties"`
	Timestamp              any            `json:"timestamp,omitempty"`
	Source                 string         `json:"source,omitempty"`
	SourceMetadata         map[string]any `json:"source_metadata,omitempty"`
	IngestedAt             string         `json:"ingested_at,omitempty"`
}

// IngestedNow is "now" in the lago-api wire format for ingested_at
// (millisecond precision, no zone suffix).
func IngestedNow() string { return time.Now().UTC().Format("2006-01-02T15:04:05.000") }

// JSON marshals v or panics (fixtures are static).
func JSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}
