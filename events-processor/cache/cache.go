package cache

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/dgraph-io/badger/v4"
	"github.com/getlago/lago/events-processor/config/database"
	"github.com/getlago/lago/events-processor/utils"
	"golang.org/x/sync/errgroup"
)

// Cache wraps BadgerDB to provide an in-memory key-value store with JSON serialization
// It manages the lifecycle of cached data and coordinates snapshot loading and CDC consumption.
type Cache struct {
	ctx                   context.Context
	db                    *badger.DB
	logger                *slog.Logger
	debeziumTopicPrefix   string
	databaseURL           string
	kafkaBootstrapServers string
	wg                    sync.WaitGroup
}

// CacheConfig holds the configuration needed to initialize a new Cache instance.
type CacheConfig struct {
	Context             context.Context
	DebeziumTopicPrefix string

	// DatabaseURL is the Postgres database the initial snapshot is loaded from.
	DatabaseURL string

	// KafkaBootstrapServers is the raw LAGO_KAFKA_BOOTSTRAP_SERVERS value,
	// used as seed broker by the change data capture consumers.
	KafkaBootstrapServers string
}

// mirroredTables lists every table kept in the cache, in loading and consumer start order.
var mirroredTables = []mirroredTable{
	billableMetricsTable,
	subscriptionsTable,
	chargesTable,
	billableMetricFiltersTable,
	chargeFiltersTable,
	chargeFilterValuesTable,
}

// NewCache creates and initializes a new in-memory cache instance.
// It configures the database with default options
func NewCache(config CacheConfig) (*Cache, error) {
	opts := badger.DefaultOptions("").WithInMemory(true)
	opts.Logger = nil

	logger := slog.Default().With("pkg", "cache")

	db, err := badger.Open(opts)
	if err != nil {
		return nil, fmt.Errorf("failed to open badger db: %w", err)
	}

	return &Cache{
		db:                    db,
		logger:                logger,
		debeziumTopicPrefix:   config.DebeziumTopicPrefix,
		databaseURL:           config.DatabaseURL,
		kafkaBootstrapServers: config.KafkaBootstrapServers,
		ctx:                   config.Context,
	}, nil
}

func (c *Cache) Close() error {
	return c.db.Close()
}

func (c *Cache) Wait() {
	c.wg.Wait()
}

func (c *Cache) LoadInitialSnapshot() {
	dbConfig := database.DBConfig{
		Url:      c.databaseURL,
		MaxConns: 10,
	}

	db, err := database.NewConnection(dbConfig)
	if err != nil {
		utils.LogAndPanic(err, "Error connecting to the database")
	}
	defer db.Close()

	errGroup := errgroup.Group{}
	defer errGroup.Wait()

	for _, table := range mirroredTables {
		errGroup.Go(func() error {
			table.loadSnapshot(c, db.Connection)
			return nil
		})
	}
}

func (c *Cache) ConsumeChanges() error {
	for _, table := range mirroredTables {
		if err := table.startConsumer(c.ctx, c); err != nil {
			return fmt.Errorf("failed to start %s consumer: %w", table.displayName(), err)
		}
	}

	return nil
}

func setJSON[T any](cache *Cache, key string, value *T) utils.Result[bool] {
	data, err := json.Marshal(value)
	if err != nil {
		return utils.FailedBoolResult(err)
	}

	err = cache.db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(key), data)
	})
	if err != nil {
		return utils.FailedBoolResult(err)
	}

	return utils.SuccessResult(true)
}

func delete(cache *Cache, key string) utils.Result[bool] {
	err := cache.db.Update(func(txn *badger.Txn) error {
		return txn.Delete([]byte(key))
	})
	if err != nil {
		return utils.FailedBoolResult(err)
	}

	return utils.SuccessResult(true)
}

// deleteWithTTL schedules a delayed deletion by setting the key with a TTL
// The key will remain accessible with its current value until the TTL expires.
func deleteWithTTL[T any](cache *Cache, key string, value *T, ttl time.Duration) utils.Result[bool] {
	data, err := json.Marshal(value)
	if err != nil {
		return utils.FailedBoolResult(err)
	}

	err = cache.db.Update(func(txn *badger.Txn) error {
		entry := badger.NewEntry([]byte(key), data).WithTTL(ttl)
		return txn.SetEntry(entry)
	})
	if err != nil {
		return utils.FailedBoolResult(err)
	}

	return utils.SuccessResult(true)
}

func getJSON[T any](cache *Cache, key string) utils.Result[*T] {
	var out T
	err := cache.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(key))
		if err != nil {
			return err
		}
		return item.Value(func(val []byte) error {
			return json.Unmarshal(val, &out)
		})
	})

	if err == badger.ErrKeyNotFound {
		return utils.FailedResult[*T](err).NonCapturable().NonRetryable()
	}
	if err != nil {
		return utils.FailedResult[*T](err)
	}

	return utils.SuccessResult(&out)
}

func searchJSON[T any](cache *Cache, prefix string) utils.Result[[]*T] {
	var results []*T

	err := cache.db.View(func(txn *badger.Txn) error {
		prefixBytes := []byte(prefix)

		// Without a prefix, the iterator would prefetch values past the matching keys
		opts := badger.DefaultIteratorOptions
		opts.Prefix = prefixBytes

		it := txn.NewIterator(opts)
		defer it.Close()

		for it.Seek(prefixBytes); it.ValidForPrefix(prefixBytes); it.Next() {
			item := it.Item()
			err := item.Value(func(val []byte) error {
				var out T
				if err := json.Unmarshal(val, &out); err != nil {
					return err
				}
				results = append(results, &out)
				return nil
			})
			if err != nil {
				return err
			}
		}
		return nil
	})

	if err != nil {
		return utils.FailedResult[[]*T](err)
	}

	return utils.SuccessResult(results)
}

func LoadSnapshot[T any](
	cache *Cache,
	name string,
	fetchFn func() ([]T, error),
	keyFn func(*T) string,
) utils.Result[int] {
	cache.logger.Info("Starting snapshot load", slog.String("model", name))
	start := time.Now()

	list, err := fetchFn()
	if err != nil {
		return utils.FailedResult[int](err)
	}

	count := 0
	for i := range list {
		item := &list[i]
		key := keyFn(item)
		if key == "" {
			continue
		}
		if res := setJSON(cache, key, item); res.Failure() {
			cache.logger.Error(
				"Failed to cache item",
				slog.String("model", name),
				slog.String("key", key),
				slog.String("error", res.ErrorMsg()),
			)
			utils.CaptureErrorResult(res)
			continue
		}
		count++
	}

	duration := time.Since(start)
	cache.logger.Info(
		"Completed snapshot load",
		slog.String("model", name),
		slog.Int("count", count),
		slog.Int64("duration_ms", duration.Milliseconds()),
	)

	return utils.SuccessResult(count)
}
