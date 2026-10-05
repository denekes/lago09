package cache

import (
	"fmt"

	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

const chargeFilterPrefix = "cf"

var chargeFiltersTable = entity[models.ChargeFilter]{
	table: "charge_filters",
	key: func(cf *models.ChargeFilter) (string, error) {
		return buildChargeFilterKey(cf.OrganizationID, cf.ChargeID, cf.ID), nil
	},
	id:        func(cf *models.ChargeFilter) string { return cf.ID },
	updatedAt: func(cf *models.ChargeFilter) utils.NullTime { return cf.UpdatedAt },
	isDeleted: func(cf *models.ChargeFilter) bool { return cf.DeletedAt.Valid },
	fetchAll:  models.GetAllChargeFilters,
}

func buildChargeFilterKey(organizationID, chargeID, id string) string {
	return fmt.Sprintf("%s:%s:%s:%s", chargeFilterPrefix, organizationID, chargeID, id)
}

func (c *Cache) SetChargeFilter(cf *models.ChargeFilter) utils.Result[bool] {
	return chargeFiltersTable.set(c, cf)
}

func (c *Cache) GetChargeFilter(organizationID, chargeID, id string) utils.Result[*models.ChargeFilter] {
	return getJSON[models.ChargeFilter](c, buildChargeFilterKey(organizationID, chargeID, id))
}

func (c *Cache) SearchChargeFilter(organizationID, chargeID string) utils.Result[[]*models.ChargeFilter] {
	prefix := fmt.Sprintf("%s:%s:%s:", chargeFilterPrefix, organizationID, chargeID)
	return searchJSON[models.ChargeFilter](c, prefix)
}

func (c *Cache) DeleteChargeFilter(cf *models.ChargeFilter) utils.Result[bool] {
	return chargeFiltersTable.remove(c, cf)
}
