// Package pipeline wires the REAL events-processor pipeline in-process:
// the real kafka.NewConsumerGroup (poll loop, per-partition consumer,
// processRecordsAndCommit, findMaxCommitableRecord), the real
// events_processor.EventProcessor (enrichment, producers, DLQ, Redis flag)
// and real kafka.Producer instances, against brokers you provide (normally a
// kfx.Cluster) and a Redis you provide (normally miniredis).
//
// It mirrors processors.StartProcessingEvents
// (events-processor/processors/main_processor.go, func StartProcessingEvents)
// minus environment parsing, SASL/TLS, the Kafka client tracer hooks
// (ServerConfig.TracerProvider) and panics. Like main.go it initialises the
// global tracer first (see New). If that function changes, re-check New below.
//
// Building this package links libexpression_go (CGO): source
// .claude/skills/build-and-env/scripts/ep-env.sh first, or use kfake-run.sh.
package pipeline

import (
	"context"
	"fmt"

	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/config/database"
	"github.com/getlago/lago/events-processor/config/kafka"
	"github.com/getlago/lago/events-processor/config/redis"
	"github.com/getlago/lago/events-processor/config/tracing"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/processors/events_processor"
)

// ProcessFunc is the signature of kafka.ConsumerGroupConfig.ProcessRecords.
// It returns the subset of records that may be committed.
type ProcessFunc = func(context.Context, []*kgo.Record) []*kgo.Record

// Config selects the topics, the data source and optional instrumentation.
type Config struct {
	Brokers        []string
	RawTopic       string // consumed
	EnrichedTopic  string // produced
	InAdvanceTopic string // produced
	DLQTopic       string // produced
	// ConsumerGroup is the PREFIX. The real group id is "<ConsumerGroup>_<RawTopic>"
	// (events-processor/config/kafka/consumer.go, NewConsumerGroup).
	ConsumerGroup string
	RedisAddr     string // e.g. miniredis.Addr(); ZSET name is subscription_refreshed_v2

	// Exactly one data source: Cache (memory-cache mode) or DB (DB mode).
	Cache *cache.Cache
	DB    *database.DB

	// Wrap, if set, wraps the real processor.ProcessEvents. Use it to observe
	// batches or inject faults (drop a record from the returned slice = the
	// retryable-failure path; panic = crash). Leave nil for production behaviour.
	Wrap func(next ProcessFunc) ProcessFunc
}

// Pipeline is a wired, not yet started, events-processor.
type Pipeline struct {
	Group     *kafka.ConsumerGroup
	Processor *events_processor.EventProcessor
	GroupID   string // the real consumer group id

	flag *models.FlagStore
}

// New builds the pipeline. It pings the brokers (producers and consumer group)
// and Redis, exactly like the binary does at startup.
func New(ctx context.Context, cfg Config) (*Pipeline, error) {
	if (cfg.Cache == nil) == (cfg.DB == nil) {
		return nil, fmt.Errorf("pipeline: set exactly one of Cache or DB")
	}
	// Like main.go: initialise the global tracer BEFORE any goroutine starts.
	// Without this, tracing.GetTracer's unsynchronised lazy init
	// (config/tracing/tracer.go GetTracer) is a data race under -race as soon
	// as two partitions are consumed concurrently. Idempotent (sync.Once).
	tracing.InitTracer(&tracing.EmptyTracerProvider{})
	server := kafka.ServerConfig{Servers: cfg.Brokers}

	mk := func(topic string) (*kafka.Producer, error) {
		p, err := kafka.NewProducer(server, &kafka.ProducerConfig{Topic: topic})
		if err != nil {
			return nil, err
		}
		return p, p.Ping(ctx)
	}
	enriched, err := mk(cfg.EnrichedTopic)
	if err != nil {
		return nil, fmt.Errorf("enriched producer: %w", err)
	}
	inAdvance, err := mk(cfg.InAdvanceTopic)
	if err != nil {
		return nil, fmt.Errorf("in-advance producer: %w", err)
	}
	dlq, err := mk(cfg.DLQTopic)
	if err != nil {
		return nil, fmt.Errorf("dlq producer: %w", err)
	}

	rdb, err := redis.NewRedisDB(ctx, redis.RedisConfig{Address: cfg.RedisAddr})
	if err != nil {
		return nil, fmt.Errorf("redis: %w", err)
	}
	flag := models.NewFlagStore(rdb, "subscription_refreshed_v2")

	var apiStore *models.ApiStore
	if cfg.DB != nil {
		apiStore = models.NewApiStore(cfg.DB)
	}
	proc := events_processor.NewEventProcessor(
		events_processor.NewEventEnrichmentService(apiStore, cfg.Cache),
		events_processor.NewEventProducerService(enriched, inAdvance, dlq),
		events_processor.NewSubscriptionRefreshService(flag),
	)

	var process ProcessFunc = proc.ProcessEvents
	if cfg.Wrap != nil {
		process = cfg.Wrap(process)
	}
	cg, err := kafka.NewConsumerGroup(server, &kafka.ConsumerGroupConfig{
		Topic:          cfg.RawTopic,
		ConsumerGroup:  cfg.ConsumerGroup,
		ProcessRecords: process,
	})
	if err != nil {
		_ = flag.Close()
		return nil, fmt.Errorf("consumer group: %w", err)
	}
	return &Pipeline{
		Group:     cg,
		Processor: proc,
		GroupID:   cfg.ConsumerGroup + "_" + cfg.RawTopic,
		flag:      flag,
	}, nil
}

// Run blocks until ctx is canceled, then performs the real graceful shutdown
// (finish in-flight batches, leave the group).
func (p *Pipeline) Run(ctx context.Context) { p.Group.Start(ctx) }

// Close releases the Redis client. Call after Run returns.
func (p *Pipeline) Close() { _ = p.flag.Close() }
