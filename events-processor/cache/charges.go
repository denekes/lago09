package cache

import (
	"fmt"

	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

const chargePrefix = "ch"

var chargesTable = entity[models.Charge]{
	table: "charges",
	key: func(ch *models.Charge) (string, error) {
		return buildChargeKey(ch.OrganizationID, ch.PlanID, ch.BillableMetricID, ch.ID), nil
	},
	id:        func(ch *models.Charge) string { return ch.ID },
	updatedAt: func(ch *models.Charge) utils.NullTime { return ch.UpdatedAt },
	isDeleted: func(ch *models.Charge) bool { return ch.DeletedAt.Valid },
	fetchAll:  models.GetAllCharges,
}

func buildChargeKey(organizationID, planID, billableMetricID, id string) string {
	return fmt.Sprintf("%s:%s:%s:%s:%s", chargePrefix, organizationID, planID, billableMetricID, id)
}

func (c *Cache) SetCharge(ch *models.Charge) utils.Result[bool] {
	return chargesTable.set(c, ch)
}

func (c *Cache) GetCharge(organizationID, planID, billableMetricID, id string) utils.Result[*models.Charge] {
	return getJSON[models.Charge](c, buildChargeKey(organizationID, planID, billableMetricID, id))
}

func (c *Cache) SearchCharge(organizationID, planID, billableMetricID string) utils.Result[[]*models.Charge] {
	prefix := fmt.Sprintf("%s:%s:%s:%s:", chargePrefix, organizationID, planID, billableMetricID)
	return searchJSON[models.Charge](c, prefix)
}

func (c *Cache) DeleteCharge(ch *models.Charge) utils.Result[bool] {
	return chargesTable.remove(c, ch)
}

// HasPayInAdvanceCharge reports whether the plan has at least one pay in advance charge for the
// billable metric.
func (c *Cache) HasPayInAdvanceCharge(organizationID, planID, billableMetricID string) utils.Result[bool] {
	chResult := c.SearchCharge(organizationID, planID, billableMetricID)
	if chResult.Failure() {
		return utils.FailedBoolResult(chResult.Error())
	}

	for _, charge := range chResult.Value() {
		if charge.PayInAdvance {
			return utils.SuccessResult(true)
		}
	}

	return utils.SuccessResult(false)
}
