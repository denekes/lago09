package cache

import (
	"fmt"

	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

const billableMetricFilterPrefix = "bmf"

var billableMetricFiltersTable = entity[models.BillableMetricFilter]{
	table: "billable_metric_filters",
	key: func(bmf *models.BillableMetricFilter) (string, error) {
		return buildBillableMetricFilterKey(bmf.OrganizationID, bmf.BillableMetricID, bmf.ID), nil
	},
	id:        func(bmf *models.BillableMetricFilter) string { return bmf.ID },
	updatedAt: func(bmf *models.BillableMetricFilter) utils.NullTime { return bmf.UpdatedAt },
	isDeleted: func(bmf *models.BillableMetricFilter) bool { return bmf.DeletedAt.Valid },
	fetchAll:  models.GetAllBillableMetricFilters,
}

func buildBillableMetricFilterKey(organizationID, billableMetricID, id string) string {
	return fmt.Sprintf("%s:%s:%s:%s", billableMetricFilterPrefix, organizationID, billableMetricID, id)
}

func (c *Cache) SetBillableMetricFilter(bmf *models.BillableMetricFilter) utils.Result[bool] {
	return billableMetricFiltersTable.set(c, bmf)
}

func (c *Cache) GetBillableMetricFilter(organizationID, billableMetricID, id string) utils.Result[*models.BillableMetricFilter] {
	return getJSON[models.BillableMetricFilter](c, buildBillableMetricFilterKey(organizationID, billableMetricID, id))
}

func (c *Cache) SearchBillableMetricFilters(organizationID, billableMetricID string) utils.Result[[]*models.BillableMetricFilter] {
	prefix := fmt.Sprintf("%s:%s:%s:", billableMetricFilterPrefix, organizationID, billableMetricID)
	return searchJSON[models.BillableMetricFilter](c, prefix)
}

func (c *Cache) DeleteBillableMetricFilter(bmf *models.BillableMetricFilter) utils.Result[bool] {
	return billableMetricFiltersTable.remove(c, bmf)
}
