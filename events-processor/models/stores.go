package models

import (
	"context"
	"fmt"
	"time"

	goredis "github.com/redis/go-redis/v9"
	"gorm.io/gorm"

	"github.com/getlago/lago/events-processor/config/database"
	"github.com/getlago/lago/events-processor/config/redis"
	"github.com/getlago/lago/events-processor/utils"
)

const SUBSCRIPTION_BUCKET_DURATION int64 = 10

type ApiStore struct {
	db *database.DB
}

func NewApiStore(db *database.DB) *ApiStore {
	return &ApiStore{
		db: db,
	}
}

type FlagStore struct {
	name string
	db   *redis.RedisDB
}

type Flagger interface {
	Flag(ctx context.Context, value string) error
}

func NewFlagStore(redis *redis.RedisDB, name string) *FlagStore {
	return &FlagStore{
		name: name,
		db:   redis,
	}
}

// Flag adds a subscription to the sorted set for delayed refresh.
// The member key includes a time bucket (value|bucket) so that events within
// the same SUBSCRIPTION_BUCKET_DURATION window share a member — ZADD overwrites the
// score to the latest event, waiting after the last event in that window.
// Once the window elapses, new events create a new member, ensuring the
// previous one ages out and gets picked up by the consumer (no starvation).
//
// The context must be scoped to the record being processed, never to the
// process lifetime: a process-wide context is canceled on shutdown, which
// would fail the write for every event still in flight.
func (store *FlagStore) Flag(ctx context.Context, value string) error {
	now := time.Now().Unix()

	// Calculate the bucket (time window) for the event
	bucket := (now / SUBSCRIPTION_BUCKET_DURATION) * SUBSCRIPTION_BUCKET_DURATION

	result := store.db.Client.ZAdd(ctx, store.name, goredis.Z{
		Score:  float64(now),
		Member: fmt.Sprintf("%s|%d", value, bucket),
	})
	if err := result.Err(); err != nil {
		return err
	}

	return nil
}

func (store *FlagStore) Close() error {
	return store.db.Client.Close()
}

// failedLookupResult wraps the error of a single record lookup. A missing record is an
// expected outcome: it is neither retried nor reported.
func failedLookupResult[T any](err error) utils.Result[T] {
	result := utils.FailedResult[T](err)

	if err.Error() == gorm.ErrRecordNotFound.Error() {
		result = result.NonCapturable().NonRetryable()
	}

	return result
}
