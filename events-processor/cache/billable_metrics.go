package cache

import (
	"fmt"

	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

const billableMetricPrefix = "bm"

var billableMetricsTable = entity[models.BillableMetric]{
	table: "billable_metrics",
	key: func(bm *models.BillableMetric) (string, error) {
		return buildBillableMetricKey(bm.OrganizationID, bm.Code), nil
	},
	id:        func(bm *models.BillableMetric) string { return bm.ID },
	updatedAt: func(bm *models.BillableMetric) utils.NullTime { return bm.UpdatedAt },
	isDeleted: func(bm *models.BillableMetric) bool { return bm.DeletedAt.Valid },
	fetchAll:  models.GetAllBillableMetrics,
}

func buildBillableMetricKey(organizationID, code string) string {
	return fmt.Sprintf("%s:%s:%s", billableMetricPrefix, organizationID, code)
}

func (c *Cache) SetBillableMetric(bm *models.BillableMetric) utils.Result[bool] {
	return billableMetricsTable.set(c, bm)
}

func (c *Cache) GetBillableMetric(organizationID, code string) utils.Result[*models.BillableMetric] {
	return getJSON[models.BillableMetric](c, buildBillableMetricKey(organizationID, code))
}

func (c *Cache) DeleteBillableMetric(bm *models.BillableMetric) utils.Result[bool] {
	return billableMetricsTable.remove(c, bm)
}
