package processors

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/config/database"
	"github.com/getlago/lago/events-processor/config/kafka"
	"github.com/getlago/lago/events-processor/config/redis"
	"github.com/getlago/lago/events-processor/config/tracing"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/processors/events_processor"
	"github.com/getlago/lago/events-processor/utils"
)

const (
	envEnv                                       = "ENV"
	envDatabaseURL                               = "DATABASE_URL"
	envLagoEventsProcessorDatabaseMaxConnections = "LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS"
	envLagoKafkaBootstrapServers                 = "LAGO_KAFKA_BOOTSTRAP_SERVERS"
	envLagoKafkaConsumerGroup                    = "LAGO_KAFKA_CONSUMER_GROUP"
	envLagoKafkaEnrichedEventsTopic              = "LAGO_KAFKA_ENRICHED_EVENTS_TOPIC"
	envLagoKafkaEventsChargedInAdvanceTopic      = "LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC"
	envLagoKafkaEventsDeadLetterTopic            = "LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC"
	envLagoKafkaPassword                         = "LAGO_KAFKA_PASSWORD"
	envLagoKafkaRawEventsTopic                   = "LAGO_KAFKA_RAW_EVENTS_TOPIC"
	envLagoKafkaScramAlgorithm                   = "LAGO_KAFKA_SCRAM_ALGORITHM"
	envLagoKafkaTLS                              = "LAGO_KAFKA_TLS"
	envLagoKafkaUsername                         = "LAGO_KAFKA_USERNAME"
	envLagoRedisCacheDB                          = "LAGO_REDIS_CACHE_DB"
	envLagoRedisCachePassword                    = "LAGO_REDIS_CACHE_PASSWORD"
	envLagoRedisCacheURL                         = "LAGO_REDIS_CACHE_URL"
	envLagoRedisCacheTLS                         = "LAGO_REDIS_CACHE_TLS"
	envLagoRedisStoreDB                          = "LAGO_REDIS_STORE_DB"
	envLagoRedisStorePassword                    = "LAGO_REDIS_STORE_PASSWORD"
	envLagoRedisStoreURL                         = "LAGO_REDIS_STORE_URL"
	envLagoRedisStoreTLS                         = "LAGO_REDIS_STORE_TLS"
)

type Config struct {
	TracerProvider tracing.TracerProvider
	Cache          *cache.Cache
}

func initProducer(ctx context.Context, kafkaConfig kafka.ServerConfig, topicEnv string) (*kafka.Producer, error) {
	if os.Getenv(topicEnv) == "" {
		return nil, fmt.Errorf("%s variable is required", topicEnv)
	}

	topic := os.Getenv(topicEnv)
	producer, err := kafka.NewProducer(
		kafkaConfig,
		&kafka.ProducerConfig{
			Topic: topic,
		})
	if err != nil {
		return nil, err
	}

	err = producer.Ping(ctx)
	if err != nil {
		return nil, err
	}

	return producer, nil
}

func initFlagStore(ctx context.Context, name string) (*models.FlagStore, error) {
	redisDb, err := utils.GetEnvAsInt(envLagoRedisStoreDB, 0)
	if err != nil {
		return nil, err
	}

	// Deprecated: Use env LAGO_REDIS_STORE_TLS instead
	legacyTLS := os.Getenv(envEnv) == "production"

	redisConfig := redis.RedisConfig{
		Address:  os.Getenv(envLagoRedisStoreURL),
		Password: os.Getenv(envLagoRedisStorePassword),
		DB:       redisDb,
		UseTLS:   utils.GetEnvAsBool(envLagoRedisStoreTLS, legacyTLS),
	}

	db, err := redis.NewRedisDB(ctx, redisConfig)
	if err != nil {
		return nil, err
	}

	return models.NewFlagStore(db, name), nil
}

// initDatabase connects to the API database, used for enrichment lookups when the in memory
// cache is disabled.
func initDatabase() *database.DB {
	maxConns, err := utils.GetEnvAsInt(envLagoEventsProcessorDatabaseMaxConnections, 200)
	if err != nil {
		utils.LogAndPanic(err, "Error converting max connections into integer")
	}

	dbConfig := database.DBConfig{
		Url:      os.Getenv(envDatabaseURL),
		MaxConns: int32(maxConns),
	}

	db, err := database.NewConnection(dbConfig)
	if err != nil {
		utils.LogAndPanic(err, "Error connecting to the database")
	}

	return db
}

func StartProcessingEvents(ctx context.Context, config *Config) {
	serverBrokers := utils.ParseBrokersEnv(os.Getenv(envLagoKafkaBootstrapServers))
	if len(serverBrokers) == 0 {
		slog.Error("brokers not found")
		panic("brokers not found")
	}

	kafkaConfig := kafka.ServerConfig{
		ScramAlgorithm: os.Getenv(envLagoKafkaScramAlgorithm),
		TLS:            utils.GetEnvAsBool(envLagoKafkaTLS, false),
		Servers:        serverBrokers,
		TracerProvider: config.TracerProvider,
		UserName:       os.Getenv(envLagoKafkaUsername),
		Password:       os.Getenv(envLagoKafkaPassword),
	}

	eventsEnrichedProducer, err := initProducer(ctx, kafkaConfig, envLagoKafkaEnrichedEventsTopic)
	if err != nil {
		utils.LogAndPanic(err, "failed to initialize enriched events producer")
	}

	eventsInAdvanceProducer, err := initProducer(ctx, kafkaConfig, envLagoKafkaEventsChargedInAdvanceTopic)
	if err != nil {
		utils.LogAndPanic(err, "failed to initialize events charged in advance producer")
	}

	eventsDeadLetterQueue, err := initProducer(ctx, kafkaConfig, envLagoKafkaEventsDeadLetterTopic)
	if err != nil {
		utils.LogAndPanic(err, "failed to initialize events dead letter queue producer")
	}

	var store events_processor.EnrichmentStore
	if config.Cache != nil {
		store = events_processor.NewCacheEnrichmentStore(config.Cache)
	} else {
		db := initDatabase()
		defer db.Close()

		store = models.NewApiStore(db)
	}

	flagger, err := initFlagStore(ctx, "subscription_refreshed_v2")
	if err != nil {
		utils.LogAndPanic(err, "Error connecting to the flag store")
	}
	defer flagger.Close()

	processor := events_processor.NewEventProcessor(
		events_processor.NewEventEnrichmentService(store),
		events_processor.NewEventProducerService(
			eventsEnrichedProducer,
			eventsInAdvanceProducer,
			eventsDeadLetterQueue,
		),
		events_processor.NewSubscriptionRefreshService(flagger),
	)

	cg, err := kafka.NewConsumerGroup(
		kafkaConfig,
		&kafka.ConsumerGroupConfig{
			Topic:          os.Getenv(envLagoKafkaRawEventsTopic),
			ConsumerGroup:  os.Getenv(envLagoKafkaConsumerGroup),
			ProcessRecords: processor.ProcessEvents,
		})
	if err != nil {
		utils.LogAndPanic(err, "Error starting the event consumer")
	}

	slog.Info("Starting event consumer")
	cg.Start(ctx)
	slog.Info("Event processor stopped")
}
