// Overlay demo for diagnostics-and-tooling (NOT part of events-processor).
//
// Mapped into events-processor/config/kafka/ ONLY in the build view by
// overlay-run.sh, so it can call the unexported findMaxCommitableRecord
// without editing the repo:
//
//	S=.claude/skills/diagnostics-and-tooling/scripts
//	$S/overlay-run.sh --no-cgo config/kafka/zz_commit_prefix_test.go=$S/overlay-examples/commit_prefix_test.go \
//	    -- -count=1 -v -run TestOverlayDemo ./config/kafka/
//
// It measures the commit decision processRecordsAndCommit makes for a 5-record
// batch (offsets 0..4) given which records ProcessRecords returned. Conclusions
// about delivery semantics belong to architecture-contract and
// event-accounting-campaign, not here.

package kafka

import (
	"testing"

	"github.com/twmb/franz-go/pkg/kgo"
)

func TestOverlayDemo_CommitPrefixTable(t *testing.T) {
	batch := make([]*kgo.Record, 5)
	for i := range batch {
		batch[i] = &kgo.Record{Offset: int64(i)}
	}
	cases := []struct {
		name      string
		processed []int
		wantOK    bool
		wantMax   int64
	}{
		{"offset 2 not returned (retryable failure)", []int{0, 1, 3, 4}, true, 1},
		{"offset 0 not returned", []int{1, 2, 3, 4}, false, -1},
		{"offsets 3 and 1 not returned", []int{0, 2, 4}, true, 0},
	}
	for _, c := range cases {
		var processed []*kgo.Record
		for _, i := range c.processed {
			processed = append(processed, batch[i])
		}
		rec, ok := findMaxCommitableRecord(processed, batch)
		got := int64(-1)
		if ok {
			got = rec.Offset
		}
		if ok != c.wantOK || got != c.wantMax {
			t.Fatalf("%s: got (offset %d, ok=%v), want (offset %d, ok=%v)", c.name, got, ok, c.wantMax, c.wantOK)
		}
		if ok {
			t.Logf("%-42s -> commit offset %d (next fetch after restart starts at %d)", c.name, got+1, got+1)
		} else {
			t.Logf("%-42s -> no commit for this batch", c.name)
		}
	}
}
