package cache

import (
	"fmt"

	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

const chargeFilterValuePrefix = "cfv"

var chargeFilterValuesTable = entity[models.ChargeFilterValue]{
	table: "charge_filter_values",
	key: func(cfv *models.ChargeFilterValue) (string, error) {
		return buildChargeFilterValueKey(cfv.OrganizationID, cfv.ChargeFilterID, cfv.BillableMetricFilterID, cfv.ID), nil
	},
	id:        func(cfv *models.ChargeFilterValue) string { return cfv.ID },
	updatedAt: func(cfv *models.ChargeFilterValue) utils.NullTime { return cfv.UpdatedAt },
	isDeleted: func(cfv *models.ChargeFilterValue) bool { return cfv.DeletedAt.Valid },
	fetchAll:  models.GetAllChargeFilterValues,
}

func buildChargeFilterValueKey(organizationID, chargeFilterID, billableMetricFilterID, id string) string {
	return fmt.Sprintf("%s:%s:%s:%s:%s", chargeFilterValuePrefix, organizationID, chargeFilterID, billableMetricFilterID, id)
}

func (c *Cache) SetChargeFilterValue(cfv *models.ChargeFilterValue) utils.Result[bool] {
	return chargeFilterValuesTable.set(c, cfv)
}

func (c *Cache) GetChargeFilterValue(organizationID, chargeFilterID, billableMetricFilterID, id string) utils.Result[*models.ChargeFilterValue] {
	return getJSON[models.ChargeFilterValue](c, buildChargeFilterValueKey(organizationID, chargeFilterID, billableMetricFilterID, id))
}

func (c *Cache) SearchChargeFilterValue(organizationID, chargeFilterID string) utils.Result[[]*models.ChargeFilterValue] {
	prefix := fmt.Sprintf("%s:%s:%s:", chargeFilterValuePrefix, organizationID, chargeFilterID)
	return searchJSON[models.ChargeFilterValue](c, prefix)
}

func (c *Cache) DeleteChargeFilterValue(cfv *models.ChargeFilterValue) utils.Result[bool] {
	return chargeFilterValuesTable.remove(c, cfv)
}
