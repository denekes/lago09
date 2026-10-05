package cache

import (
	"fmt"
	"log/slog"
	"time"

	"github.com/dgraph-io/badger/v4"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

const subscriptionPrefix = "sub"

var subscriptionsTable = entity[models.Subscription]{
	table:     "subscriptions",
	key:       subscriptionKey,
	id:        func(sub *models.Subscription) string { return sub.ID },
	updatedAt: func(sub *models.Subscription) utils.NullTime { return sub.UpdatedAt },
	// A terminated subscription is handled as a deletion
	isDeleted: func(sub *models.Subscription) bool { return sub.TerminatedAt.Valid },
	fetchAll:  models.GetAllSubscriptions,
	// Since we want to keep terminated subscriptions to permit grace period events backfill
	// we update the cache entry with a 1 month TTL
	deleteTTL: 30 * 24 * time.Hour,
}

func buildSubscriptionKey(organizationID, externalID, ID string) string {
	return fmt.Sprintf("%s:%s:%s:%s", subscriptionPrefix, organizationID, externalID, ID)
}

func subscriptionKey(sub *models.Subscription) (string, error) {
	if sub.OrganizationID == nil {
		return "", fmt.Errorf("subscription %s has nil OrganizationID", sub.ID)
	}
	return buildSubscriptionKey(*sub.OrganizationID, sub.ExternalID, sub.ID), nil
}

func (c *Cache) SetSubscription(sub *models.Subscription) utils.Result[bool] {
	return subscriptionsTable.set(c, sub)
}

func (c *Cache) GetSubscription(organizationID, externalID, ID string) utils.Result[*models.Subscription] {
	return getJSON[models.Subscription](c, buildSubscriptionKey(organizationID, externalID, ID))
}

func (c *Cache) SearchSubscriptions(organizationID string, externalID string, timestamp time.Time) utils.Result[*models.Subscription] {
	prefix := fmt.Sprintf("%s:%s:%s:", subscriptionPrefix, organizationID, externalID)
	result := searchJSON[models.Subscription](c, prefix)

	if result.Failure() {
		return utils.FailedResult[*models.Subscription](result.Error())
	}

	subscriptions := result.Value()
	var validSubs []*models.Subscription
	for _, sub := range subscriptions {
		if !sub.StartedAt.Valid {
			continue
		}

		if sub.StartedAt.Time.After(timestamp) {
			continue
		}

		// Check if subscription is not terminated or terminated after the timestamp
		if !sub.TerminatedAt.Valid || sub.TerminatedAt.Time.After(timestamp) || sub.TerminatedAt.Time.Equal(timestamp) {
			validSubs = append(validSubs, sub)
		}
	}

	var bestMatch *models.Subscription
	for _, sub := range validSubs {
		if bestMatch == nil {
			bestMatch = sub
			continue
		}

		// Simulates NULL FIRST for terminated_at
		if !bestMatch.TerminatedAt.Valid && sub.TerminatedAt.Valid {
			continue
		}
		if bestMatch.TerminatedAt.Valid && !sub.TerminatedAt.Valid {
			bestMatch = sub
			continue
		}

		// Both have terminated_at or both are NULL
		if bestMatch.TerminatedAt.Valid && sub.TerminatedAt.Valid {
			if sub.TerminatedAt.Time.After(bestMatch.TerminatedAt.Time) {
				bestMatch = sub
				continue
			}
			if sub.TerminatedAt.Time.Before(bestMatch.TerminatedAt.Time) {
				continue
			}
		}

		// If terminated_at is equal (or both NULL), compare started_at DESC
		if sub.StartedAt.Valid && bestMatch.StartedAt.Valid {
			if sub.StartedAt.Time.After(bestMatch.StartedAt.Time) {
				bestMatch = sub
			}
		}
	}

	if bestMatch == nil {
		err := badger.ErrKeyNotFound
		return utils.FailedResult[*models.Subscription](err).
			NonCapturable().NonRetryable()
	} else {
		c.logger.Debug(
			"search subscription result",
			slog.String("subscription external id: ", bestMatch.ExternalID),
		)
	}

	return utils.SuccessResult(bestMatch)
}

func (c *Cache) DeleteSubscription(sub *models.Subscription) utils.Result[bool] {
	return subscriptionsTable.remove(c, sub)
}
