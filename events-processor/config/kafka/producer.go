package kafka

import (
	"context"
	"log/slog"

	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/getlago/lago/events-processor/config/tracing"
	"github.com/getlago/lago/events-processor/utils"
)

type ProducerConfig struct {
	Topic string
}

type Producer struct {
	client *kgo.Client
	config ProducerConfig
	logger *slog.Logger
}

type ProducerMessage struct {
	Key   []byte
	Value []byte
}

type MessageProducer interface {
	Produce(context.Context, *ProducerMessage) bool
	GetTopic() string
}

func NewProducer(serverConfig ServerConfig, cfg *ProducerConfig) (*Producer, error) {
	kcl, err := NewKafkaClient(serverConfig, nil)
	if err != nil {
		return nil, err
	}

	pdr := &Producer{
		client: kcl,
		config: *cfg,
		logger: newLogger("component", "kafka-producer"),
	}

	return pdr, nil
}

func (p *Producer) Produce(ctx context.Context, msg *ProducerMessage) bool {
	span := tracing.StartSpan(ctx, "Producer.Produce")
	defer span.End()

	record := &kgo.Record{
		Topic: p.config.Topic,
		Key:   msg.Key,
		Value: msg.Value,
	}

	pr := p.client.ProduceSync(ctx, record)
	if err := pr.FirstErr(); err != nil {
		p.logger.Error("record had a produce error while synchronously producing", slog.String("error", err.Error()))
		utils.CaptureError(err)
		return false
	}

	return true
}

func (p *Producer) Ping(ctx context.Context) error {
	return p.client.Ping(ctx)
}

func (p *Producer) GetTopic() string {
	return p.config.Topic
}
