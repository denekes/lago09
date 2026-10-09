package events_processor

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/getlago/lago/events-processor/config/kafka"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

type EventProducerService struct {
	enrichedProducer   kafka.MessageProducer
	inAdvanceProducer  kafka.MessageProducer
	deadLetterProducer kafka.MessageProducer
}

func NewEventProducerService(enrichedProducer, inAdvanceProducer, deadLetterProducer kafka.MessageProducer) *EventProducerService {
	return &EventProducerService{
		enrichedProducer:   enrichedProducer,
		inAdvanceProducer:  inAdvanceProducer,
		deadLetterProducer: deadLetterProducer,
	}
}

func (eps *EventProducerService) ProduceEnrichedEvent(ctx context.Context, event *models.EnrichedEvent) {
	eps.produceEvent(ctx, eps.enrichedProducer, event, "error while marshaling enriched events")
}

func (eps *EventProducerService) ProduceChargedInAdvanceEvent(ctx context.Context, event *models.EnrichedEvent) {
	eps.produceEvent(ctx, eps.inAdvanceProducer, event, "error while marshaling charged in advance events")
}

func (eps *EventProducerService) ProduceToDeadLetterQueue(ctx context.Context, event models.Event, errorResult utils.AnyResult) {
	failedEvent := models.FailedEvent{
		Event:               event,
		InitialErrorMessage: errorResult.ErrorMsg(),
		ErrorCode:           errorResult.ErrorCode(),
		ErrorMessage:        errorResult.ErrorMessage(),
		FailedAt:            time.Now(),
	}

	eventJson, err := json.Marshal(failedEvent)
	if err != nil {
		slog.Error("error while marshaling failed event with error details")
		utils.CaptureError(err)
	}

	pushed := eps.deadLetterProducer.Produce(ctx, &kafka.ProducerMessage{
		Value: eventJson,
	})

	if !pushed {
		slog.Error("error while pushing to dead letter topic", slog.String("topic", eps.deadLetterProducer.GetTopic()))
		utils.CaptureErrorResultWithExtra(errorResult, "event", event)
	}
}

// produceEvent sends the event keyed by organization and transaction. When the producer
// fails to send it, the initial event is pushed to the dead letter queue.
func (eps *EventProducerService) produceEvent(ctx context.Context, producer kafka.MessageProducer, event *models.EnrichedEvent, marshalErrorMessage string) {
	eventJson, err := json.Marshal(event)
	if err != nil {
		slog.Error(marshalErrorMessage)
		utils.CaptureError(err)
		return
	}

	pushed := producer.Produce(ctx, &kafka.ProducerMessage{
		Key:   []byte(fmt.Sprintf("%s-%s", event.OrganizationID, event.TransactionID)),
		Value: eventJson,
	})

	if !pushed {
		eps.ProduceToDeadLetterQueue(ctx, *event.InitialEvent, utils.FailedBoolResult(fmt.Errorf("failed to push to %s topic", producer.GetTopic())))
	}
}
