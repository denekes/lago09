package events_processor

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"golang.org/x/sync/errgroup"

	"github.com/getlago/lago/events-processor/config/tracing"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

// retryWindow is how long a retryable failure is left uncommitted to be consumed again.
// Older events are pushed to the dead letter queue instead.
const retryWindow = 12 * time.Hour

type EventProcessor struct {
	EnrichmentService *EventEnrichmentService
	ProducerService   *EventProducerService
	RefreshService    *SubscriptionRefreshService
}

func NewEventProcessor(enrichmentService *EventEnrichmentService, producerService *EventProducerService, refreshService *SubscriptionRefreshService) *EventProcessor {
	return &EventProcessor{
		EnrichmentService: enrichmentService,
		ProducerService:   producerService,
		RefreshService:    refreshService,
	}
}

// ProcessEvents processes the records concurrently and returns the ones that can be committed.
func (processor *EventProcessor) ProcessEvents(ctx context.Context, records []*kgo.Record) []*kgo.Record {
	span := tracing.StartSpan(ctx, "PostProcess.ProcessEvents")
	defer span.End()

	span.SetAttribute("records.length", len(records))

	var (
		g  errgroup.Group
		mu sync.Mutex
	)
	processedRecords := make([]*kgo.Record, 0)

	for _, record := range records {
		g.Go(func() error {
			if processor.processRecord(ctx, record) {
				mu.Lock()
				processedRecords = append(processedRecords, record)
				mu.Unlock()
			}
			return nil
		})
	}

	_ = g.Wait()
	return processedRecords
}

// processRecord processes one record and reports whether it can be committed: it is kept
// uncommitted only when it failed with a retryable error within the retry window.
func (processor *EventProcessor) processRecord(ctx context.Context, record *kgo.Record) bool {
	sp := tracing.StartSpan(ctx, "PostProcess.ProcessOneEvent")
	defer sp.End()

	event := models.Event{}
	if err := json.Unmarshal(record.Value, &event); err != nil {
		slog.Error("Error unmarshalling message", slog.String("error", err.Error()))
		utils.CaptureError(err)

		// If we fail to unmarshal the record, we should commit it as it will fail forever
		return true
	}

	result := processor.processEvent(ctx, &event)
	if result.Success() {
		return true
	}

	slog.Error(
		result.ErrorMessage(),
		slog.String("error_code", result.ErrorCode()),
		slog.String("error", result.ErrorMsg()),
	)

	if result.IsCapturable() {
		utils.CaptureErrorResultWithExtra(result, "event", event)
	}

	if result.IsRetryable() && time.Since(event.IngestedAt.Time()) < retryWindow {
		// For retryable errors, we should avoid committing the record,
		// It will be consumed again and reprocessed
		return false
	}

	// Push failed records to the dead letter queue
	processor.ProducerService.ProduceToDeadLetterQueue(ctx, event, result)
	return true
}

func (processor *EventProcessor) processEvent(ctx context.Context, event *models.Event) utils.Result[*models.EnrichedEvent] {
	// Produced messages are sent concurrently, the event is done once they are all sent
	var producers errgroup.Group
	defer producers.Wait()

	enrichedEventResult := processor.EnrichmentService.EnrichEvent(event)
	if enrichedEventResult.Failure() {
		return failedResult(enrichedEventResult, enrichedEventResult.ErrorCode(), enrichedEventResult.ErrorMessage())
	}

	enrichedEvent := enrichedEventResult.Value()

	producers.Go(func() error {
		processor.ProducerService.ProduceEnrichedEvent(ctx, enrichedEvent)
		return nil
	})

	if enrichedEvent.Subscription != nil && event.NotAPIPostProcessed() {
		payInAdvanceResult := processor.EnrichmentService.HasPayInAdvanceCharge(enrichedEvent)
		if payInAdvanceResult.Failure() {
			return failedResult(payInAdvanceResult, "fetch_pay_in_advance_charge", "Error fetching pay in advance charge")
		}

		if payInAdvanceResult.Value() {
			producers.Go(func() error {
				processor.ProducerService.ProduceChargedInAdvanceEvent(ctx, enrichedEvent)
				return nil
			})
		}

		flagResult := processor.RefreshService.FlagSubscriptionRefresh(ctx, enrichedEvent)
		if flagResult.Failure() {
			return failedResult(flagResult, "flag_subscription_refresh", "Error flagging subscription refresh")
		}
	}

	return utils.SuccessResult(enrichedEvent)
}

func failedResult(r utils.AnyResult, code string, message string) utils.Result[*models.EnrichedEvent] {
	result := utils.FailedResult[*models.EnrichedEvent](r.Error()).AddErrorDetails(code, message)
	result.Retryable = r.IsRetryable()
	result.Capture = r.IsCapturable()
	return result
}
