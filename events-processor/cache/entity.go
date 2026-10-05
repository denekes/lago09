package cache

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"gorm.io/gorm"

	"github.com/getlago/lago/events-processor/utils"
)

// entity describes how one Postgres table is mirrored into the cache: how its rows are keyed,
// how the initial snapshot is fetched and how Debezium change events are applied to it.
type entity[T any] struct {
	// table is the Postgres table name. It is also the suffix of the Debezium topic
	// and the "model" attribute of the logs.
	table string

	key       func(*T) (string, error)
	id        func(*T) string
	updatedAt func(*T) utils.NullTime
	isDeleted func(*T) bool
	fetchAll  func(*gorm.DB) utils.Result[[]T]

	// deleteTTL, when set, keeps deleted entries readable for that duration instead of
	// removing them right away.
	deleteTTL time.Duration
}

// mirroredTable is the type-erased view of an entity, used to run every table through
// the same snapshot and change consumption steps.
type mirroredTable interface {
	displayName() string
	loadSnapshot(c *Cache, db *gorm.DB) utils.Result[int]
	startConsumer(ctx context.Context, c *Cache) error
}

func (e entity[T]) displayName() string {
	return strings.ReplaceAll(e.table, "_", " ")
}

func (e entity[T]) set(c *Cache, item *T) utils.Result[bool] {
	key, err := e.key(item)
	if err != nil {
		return utils.FailedBoolResult(err)
	}
	return setJSON(c, key, item)
}

func (e entity[T]) get(c *Cache, item *T) utils.Result[*T] {
	key, err := e.key(item)
	if err != nil {
		return utils.FailedResult[*T](err)
	}
	return getJSON[T](c, key)
}

func (e entity[T]) remove(c *Cache, item *T) utils.Result[bool] {
	key, err := e.key(item)
	if err != nil {
		return utils.FailedBoolResult(err)
	}
	if e.deleteTTL > 0 {
		return deleteWithTTL(c, key, item, e.deleteTTL)
	}
	return delete(c, key)
}

func (e entity[T]) loadSnapshot(c *Cache, db *gorm.DB) utils.Result[int] {
	return LoadSnapshot(
		c,
		e.table,
		func() ([]T, error) {
			res := e.fetchAll(db)
			if res.Failure() {
				return nil, res.Error()
			}
			return res.Value(), nil
		},
		func(item *T) string {
			key, err := e.key(item)
			if err != nil {
				c.logger.Error(
					"Skipping item in snapshot",
					slog.String("model", e.table),
					slog.String("error", err.Error()),
				)
				return ""
			}
			return key
		},
	)
}

func (e entity[T]) consumerConfig(c *Cache) ConsumerConfig[T] {
	return ConsumerConfig[T]{
		Topic:     c.debeziumTopicPrefix + ".public." + e.table,
		ModelName: e.table,
		IsDeleted: e.isDeleted,
		GetKey: func(item *T) string {
			// Only used for logging. A key error makes GetCached, SetCache and Delete fail.
			key, _ := e.key(item)
			return key
		},
		GetID: e.id,
		GetUpdatedAt: func(item *T) int64 {
			return e.updatedAt(item).Time.UnixMilli()
		},
		GetCached: func(item *T) utils.Result[*T] {
			return e.get(c, item)
		},
		SetCache: func(item *T) utils.Result[bool] {
			return e.set(c, item)
		},
		Delete: func(item *T) utils.Result[bool] {
			return e.remove(c, item)
		},
	}
}

func (e entity[T]) startConsumer(ctx context.Context, c *Cache) error {
	return startGenericConsumer(ctx, c, e.consumerConfig(c))
}
