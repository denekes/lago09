package events_processor

import (
	"time"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

// EnrichmentStore is the read model used to enrich events. It is backed either by the
// Postgres database (models.ApiStore) or by the in-memory cache (see NewCacheEnrichmentStore).
//
// Lookups of missing records must fail with a non capturable and non retryable result.
type EnrichmentStore interface {
	FetchBillableMetric(organizationID string, code string) utils.Result[*models.BillableMetric]
	FetchSubscription(organizationID string, externalID string, timestamp time.Time) utils.Result[*models.Subscription]
	HasPayInAdvanceCharge(organizationID string, planID string, billableMetricID string) utils.Result[bool]
}

var _ EnrichmentStore = (*models.ApiStore)(nil)

type cacheEnrichmentStore struct {
	*cache.Cache
}

// NewCacheEnrichmentStore serves enrichment lookups from the in-memory cache.
func NewCacheEnrichmentStore(memCache *cache.Cache) EnrichmentStore {
	return cacheEnrichmentStore{Cache: memCache}
}

func (s cacheEnrichmentStore) FetchBillableMetric(organizationID string, code string) utils.Result[*models.BillableMetric] {
	return s.GetBillableMetric(organizationID, code)
}

func (s cacheEnrichmentStore) FetchSubscription(organizationID string, externalID string, timestamp time.Time) utils.Result[*models.Subscription] {
	return s.SearchSubscriptions(organizationID, externalID, timestamp)
}
