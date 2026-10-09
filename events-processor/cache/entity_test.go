package cache

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

func TestMirroredTables(t *testing.T) {
	cache, err := NewCache(CacheConfig{
		Context:             context.Background(),
		DebeziumTopicPrefix: "lago_dbz",
	})
	require.NoError(t, err)
	t.Cleanup(func() { cache.Close() })

	expected := []struct {
		displayName string
		topic       string
		modelName   string
	}{
		{"billable metrics", "lago_dbz.public.billable_metrics", "billable_metrics"},
		{"subscriptions", "lago_dbz.public.subscriptions", "subscriptions"},
		{"charges", "lago_dbz.public.charges", "charges"},
		{"billable metric filters", "lago_dbz.public.billable_metric_filters", "billable_metric_filters"},
		{"charge filters", "lago_dbz.public.charge_filters", "charge_filters"},
		{"charge filter values", "lago_dbz.public.charge_filter_values", "charge_filter_values"},
	}

	configs := []struct {
		topic     string
		modelName string
	}{
		{billableMetricsTable.consumerConfig(cache).Topic, billableMetricsTable.consumerConfig(cache).ModelName},
		{subscriptionsTable.consumerConfig(cache).Topic, subscriptionsTable.consumerConfig(cache).ModelName},
		{chargesTable.consumerConfig(cache).Topic, chargesTable.consumerConfig(cache).ModelName},
		{billableMetricFiltersTable.consumerConfig(cache).Topic, billableMetricFiltersTable.consumerConfig(cache).ModelName},
		{chargeFiltersTable.consumerConfig(cache).Topic, chargeFiltersTable.consumerConfig(cache).ModelName},
		{chargeFilterValuesTable.consumerConfig(cache).Topic, chargeFilterValuesTable.consumerConfig(cache).ModelName},
	}

	require.Len(t, mirroredTables, len(expected))
	for i, table := range mirroredTables {
		assert.Equal(t, expected[i].displayName, table.displayName())
		assert.Equal(t, expected[i].topic, configs[i].topic)
		assert.Equal(t, expected[i].modelName, configs[i].modelName)
	}
}

func TestEntityConsumerConfig_DeletedSemantics(t *testing.T) {
	deleted := utils.NowNullTime()

	assert.True(t, billableMetricsTable.isDeleted(&models.BillableMetric{DeletedAt: deleted}))
	assert.False(t, billableMetricsTable.isDeleted(&models.BillableMetric{}))
	assert.True(t, chargesTable.isDeleted(&models.Charge{DeletedAt: deleted}))
	assert.True(t, billableMetricFiltersTable.isDeleted(&models.BillableMetricFilter{DeletedAt: deleted}))
	assert.True(t, chargeFiltersTable.isDeleted(&models.ChargeFilter{DeletedAt: deleted}))
	assert.True(t, chargeFilterValuesTable.isDeleted(&models.ChargeFilterValue{DeletedAt: deleted}))

	// A terminated subscription is handled as a deletion
	assert.True(t, subscriptionsTable.isDeleted(&models.Subscription{TerminatedAt: deleted}))
	assert.False(t, subscriptionsTable.isDeleted(&models.Subscription{}))
	assert.Equal(t, 30*24*time.Hour, subscriptionsTable.deleteTTL)
	assert.Zero(t, chargesTable.deleteTTL)
}

func TestEntityConsumerConfig_AppliesChanges(t *testing.T) {
	cache := setupTestCache(t)
	config := chargesTable.consumerConfig(cache)

	updatedAt := utils.NewNullTime(time.UnixMilli(1700000000123))
	charge := &models.Charge{
		ID:               "ch1",
		OrganizationID:   "org1",
		PlanID:           "plan1",
		BillableMetricID: "bm1",
		UpdatedAt:        updatedAt,
	}

	assert.Equal(t, "ch:org1:plan1:bm1:ch1", config.GetKey(charge))
	assert.Equal(t, "ch1", config.GetID(charge))
	assert.Equal(t, int64(1700000000123), config.GetUpdatedAt(charge))

	require.True(t, config.SetCache(charge).Success())
	cached := config.GetCached(charge)
	require.True(t, cached.Success())
	assert.Equal(t, "ch1", cached.Value().ID)

	require.True(t, config.Delete(charge).Success())
	assert.True(t, config.GetCached(charge).Failure())
}
